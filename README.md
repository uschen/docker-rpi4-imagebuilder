
# Creating a RPI4 boot image in a Docker container from a current Ubuntu RPI3 boot image

(Largely adapted from project at https://github.com/tsaarni/docker-deb-builder )

## Overview

This creates a docker container to build an Ubuntu 19.10 server image for a Raspberry Pi 4B using unstable/current software.
A new kernel is compiled, and current firmware is copied into the container.

## Create build environment

Start by building a container that will act as package build environment:

    docker build -t docker-rpi4-imagebuilder:19.10 -f Dockerfile-ubuntu-19.10 .

In this example the target is Ubuntu 19.10 but you can create and
modify `Dockerfile-nnn` to match your target environment.

## Building packages

Clone the
[docker-rpi4-imagebuilder](https://github.com/satmandu/docker-rpi4-imagebuilder)
(the repository you are reading now) and run the build script to see
usage:


    $ git clone https://github.com/satmandu/docker-rpi4-imagebuilder
    $ cd docker-rpi4-imagebuilder
    $ ./build-image
    usage: build [options...] SOURCEDIR
    Options:
      -i IMAGE  Name of the docker image (including tag) to use as package build environment.
      -o DIR    Destination directory to store output compressed image to.

To build an Ubuntu Eoan Raspberry Pi 4B image run following commands:

    # create destination directory to store the build results
    mkdir output
    
    

    # MAKE SURE YOU HAVE ALREADY MADE YOUR BUILD ENVIRONMENT CONTAINER like thus:
    docker build -t docker-rpi4-imagebuilder:19.10 -f Dockerfile-ubuntu-19.10 .

    # build package from source directory
    # ./build-image -i docker-rpi4-imagebuilder:19.10 -o output ~/directory_with_the_scripts
    time ./build-image -i docker-rpi4-imagebuilder:19.10 -o output .
    
A first build takes about 30 min on my Skylake build machine.

This takes about ten minutes the second time through due to the use of ccache.
The build will be even faster if you disable xz compression in the list of 
image compressors used at the top of the build-rpi4.sh file.



After a successful build you will find the `eoan-preinstalled-server-arm64+raspi4.img___kernel___timestamp.lz4` 
file in your specified `output` directory. (Failure will lead to a build_fail.log in that folder.)

## Installing image to sd card

Use the instructions here: https://ubuntu.com/download/iot/installation-media

Example: ```lz4cat ~/Downloads/eoan-preinstalled-server-arm64+raspi4.img.lz4 | sudo dd of=< drive address > bs=32M ```
or ```xzcat ~/Downloads/eoan-preinstalled-server-arm64+raspi4.img.xz | sudo dd of=< drive address > bs=32M ```

Note that you want to replace instances of "xzcat" with "lzcat" since this setup uses the much faster lz4 to compress the images created in the docker container.

## 1st Login
The **default login for this image is unchanged** from the ubuntu server default image: **ubuntu/ubuntu**.
Note also that the **RPI4 SHOULD Be connected to ethernet for first login**, as the ubuntu startup cloud sequence wants a connection.
After the network starts, you should be able to ssh to the IP of the RPI with username ubuntu, where you will be prompted to change the password. As the ubuntu cloud setup is not disabled, you have to wait about five minutes for login to be available.

Do setup the Time Zone using ```sudo dpkg-reconfigure tzdata```. You can also use ```nmtui``` to configure the wireless network after doing ```sudo apt install network-manager```.

