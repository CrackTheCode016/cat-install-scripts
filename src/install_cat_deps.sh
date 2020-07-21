#!/bin/bash

if [ "$#" < 2 ]; then
    echo "dependencies directory and core count is required"
    exit 1
fi

if [ ! -d "$1" ]; then
    echo $1
    echo "dependencies directory must exist"
    exit 1
fi

if [[ $1 == .* ]]; then
    echo "absolute path required"
    exit 1
fi

compiler=
lib_suffix=
openssl_dir=
CATAPULT_VERSION=v0.9.6.3

if [[ $OSTYPE == "linux"* ]]; then
    compiler="gcc"
    lib_suffix="so"
    # use manual install
    openssl_dir="/opt/openssl/openssl-1.1.1f"
    elif [[ $OSTYPE == "darwin"* ]]; then
    compiler="clang"
    lib_suffix="dylib"
    # target Brew install
    openssl_dir="/usr/local/opt/openssl@1.1"
else
    echo "OS not supported."
    echo
    exit 1
fi

if [[ $3 != "" ]]; then
    echo "Attempting to install Catapult version $3"
    CATAPULT_VERSION=$3
fi

deps_dir=$1
job_count=$2
boost_output_dir=${deps_dir}/boost
gtest_output_dir=${deps_dir}/gtest
mongo_output_dir=${deps_dir}/mongodb
zmq_output_dir=${deps_dir}/zeromq
rocksdb_output_dir=${deps_dir}/rocksdb

echo "Detected system ${OSTYPE}, using ${compiler} compiler and library suffix ${lib_suffix}."
echo
echo "boost_output_dir: ${boost_output_dir}"
echo "gtest_output_dir: ${gtest_output_dir}"
echo "mongo_output_dir: ${mongo_output_dir}"
echo "zmq_output_dir: ${zmq_output_dir}"
echo "rocksdb_output_dir: ${rocksdb_output_dir}"
echo

# region boost

function install_boost {
    local boost_ver=1_71_0
    local boost_ver_dotted=1.71.0
    
    if [[ ! -f "${deps_dir}/source/boost_${boost_ver}.tar.gz" ]]; then
        curl -o boost_${boost_ver}.tar.gz -SL https://dl.bintray.com/boostorg/release/${boost_ver_dotted}/source/boost_${boost_ver}.tar.gz
        tar -xzf boost_${boost_ver}.tar.gz
        cd boost_${boost_ver}
    fi
    
    mkdir ${boost_output_dir}
    ./bootstrap.sh with-toolset=${compiler} --prefix=${boost_output_dir}
    
    b2_options=()
    b2_options+=(toolset=${compiler})
    b2_options+=(--without-python)
    # b2_options+=(cxxflags='-std=c++1y -stdlib=libc++')
    # b2_options+=(linkflags='-stdlib=libc++')
    b2_options+=(--prefix=${boost_output_dir})
    
    ./b2 ${b2_options[@]} -j ${job_count} stage release
    ./b2 install ${b2_options[@]}
}

# endregion

# region google test + benchmark

function install_git_dependency {
    git clone git://github.com/${1}/${2}.git
    cd ${2}
    git checkout ${3}
    
    
    if [[ $2 == "mongo-cxx-driver" ]]; then
        sed -i 's/kvp("maxAwaitTimeMS", count)/kvp("maxAwaitTimeMS", static_cast<int64_t>(count))/' src/mongocxx/options/change_stream.cpp
    fi
    
    mkdir _build
    cd _build
    
    cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX="${deps_dir}/${1}" ${cmake_options[@]} ..
    make
    make install
}

function install_google_test {
    cmake_options=()
    # cmake_options+=(-DCMAKE_CXX_FLAGS='-std=c++11 -stdlib=libc++')
    cmake_options+=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON)
    cmake_options+=(-DCMAKE_BUILD_TYPE=Release)
    install_git_dependency google googletest release-1.8.1
}

function install_google_benchmark {
    cmake_options=()
    # cmake_options+=(-DCMAKE_CXX_FLAGS='-std=c++11 -stdlib=libc++')
    cmake_options+=(-DBENCHMARK_ENABLE_GTEST_TESTS=OFF)
    cmake_options+=(-DCMAKE_BUILD_TYPE=Release)
    install_git_dependency google benchmark v1.5.0
}

# endregion

# region mongo

function install_mongo_c_driver {
    cmake_options=(-DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF)
    install_git_dependency mongodb mongo-c-driver 1.15.1
}

function install_mongo_cxx_driver {
    # hotfix
    export CMAKE_PREFIX_PATH=${mongo_output_dir}/lib/cmake/libbson-1.0/:${mongo_output_dir}/lib/cmake/libmongoc-1.0/
    cmake_options=()
    cmake_options+=(-DBOOST_ROOT=${boost_output_dir})
    cmake_options+=(-DLIBBSON_DIR=${mongo_output_dir})
    cmake_options+=(-DLIBMONGOC_DIR=${mongo_output_dir})
    cmake_options+=(-DBSONCXX_POLY_USE_BOOST=1)
    cmake_options+=(-DCMAKE_BUILD_TYPE=Release)
    
    install_git_dependency mongodb mongo-cxx-driver r3.4.0
}

# endregion

# region zmq

function install_zmq_lib {
    # cmake_options=(-DCMAKE_CXX_FLAGS='-std=c++11 -stdlib=libc++')
    cmake_options=(-DCMAKE_BUILD_TYPE=Release)
    install_git_dependency zeromq libzmq v4.3.2
}

function install_zmq_cpp {
    cmake_options=()
    # cmake_options=(-DCMAKE_CXX_FLAGS='-std=c++11 -stdlib=libc++')
    cmake_options=(-DCMAKE_BUILD_TYPE=Release)
    cmake_options=(-DCPPZMQ_BUILD_TESTS=OFF)
    install_git_dependency zeromq cppzmq v4.4.1
}

# endregion

# region rocksdb

function install_rocksdb {
    # using https://github.com/nemtech/rocksdb.git as work-around for now
    git clone https://github.com/nemtech/rocksdb.git
    cd rocksdb
    git checkout v6.6.4-nem
    INSTALL_PATH=${rocksdb_output_dir} CFLAGS="-Wno-error" make install-shared
}

# endregion

# region catapult

function install_catapult {
    cmake_options=()
    
    ## BOOST ##
    cmake_options+=(-DBOOST_ROOT=${boost_output_dir})
    cmake_options+=(-DCMAKE_PREFIX_PATH="${mongo_output_dir}/lib/cmake/libmongoc-1.0;${mongo_output_dir}/lib/cmake/libmongocxx-3.4.0;${mongo_output_dir}/lib/cmake/libbsoncxx-3.4.0;${mongo_output_dir}/lib/cmake/libbson-1.0")
    
    ## ROCKSDB ##
    cmake_options+=(-DROCKSDB_LIBRARIES=${rocksdb_output_dir}/lib/librocksdb.${lib_suffix})
    cmake_options+=(-DROCKSDB_INCLUDE_DIR=${rocksdb_output_dir}/include)
    
    ## GTEST & BENCHMARK ##
    cmake_options+=(-Dbenchmark_DIR=${deps_dir}/google/lib/cmake/benchmark)
    cmake_options+=(-DGTEST_ROOT=${deps_dir}/google)
    
    ## ZMQ ##
    cmake_options+=(-Dcppzmq_DIR=${zmq_output_dir}/share/cmake/cppzmq)
    cmake_options+=(-DZeroMQ_DIR=${zmq_output_dir}/share/cmake/ZeroMQ)
    
    ## MONGO ##
    cmake_options+=(-DLIBMONGOCXX_LIBRARY_DIRS=${mongo_output_dir})
    cmake_options+=(-DMONGOC_LIB=${mongo_output_dir}/lib/libmongoc-1.0.${lib_suffix})
    cmake_options+=(-DBSONC_LIB=${mongo_output_dir}/lib/libbsonc-1.0.${lib_suffix})
    
    
    ## OPENSSL ##
    cmake_options+=(-DOPENSSL_ROOT_DIR=${openssl_dir})
    
    ## OTHER ##
    cmake_options+=(-DCMAKE_BUILD_TYPE=Release)
    cmake_options+=(-G)
    cmake_options+=(Ninja)
    
    git clone https://github.com/nemtech/catapult-server.git --single-branch --branch ${CATAPULT_VERSION}
    cd catapult-server
    
    mkdir _build
    cd _build
    
    cmake ${cmake_options[@]} ..
    
    ninja publish
    ninja -j ${job_count}
}

# endregion

cd ${deps_dir}
mkdir source

declare -a installers=(
    install_boost
    install_google_test
    install_google_benchmark
    install_mongo_c_driver
    install_mongo_cxx_driver
    install_zmq_lib
    install_zmq_cpp
    install_rocksdb
    install_catapult
)
if [[ $4 == "rebuild" || $3 == "rebuild" ]]; then
    echo "Rebuilding Catapult"
    pushd source > /dev/null
    install_catapult
    popd > /dev/null
else
    for install in "${installers[@]}"
    do
        pushd source > /dev/null
        ${install}
        popd > /dev/null
    done
fi