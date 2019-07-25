
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

    $ ./build-image
    usage: build [options...] SOURCEDIR
    Options:
      -i IMAGE  Name of the docker image (including tag) to use as package build environment.
      -o DIR    Destination directory to store output compressed image to.

To build an Ubuntu Eoan Raspberry Pi 4B image run following commands:

    # create destination directory to store the build results
    mkdir output

    # build package from source directory
    # ./build-image -i docker-rpi4-imagebuilder:19.10 -o output ~/directory_with_the_scripts
    ./build-image -i docker-rpi4-imagebuilder:19.10 -o output .



After successful build you will find the `eoan-preinstalled-server-arm64+raspi4.img.lz4` file in the `output`
directory.

## Installing image to sd card

Use the instructions here: https://ubuntu.com/download/iot/installation-media

Example: lz4cat ~/Downloads/ < image file .lz4 > | sudo dd of=< drive address > bs=32M

Note that you want to replace instances of "xzcat" with "lzcat" since this setup uses the much faster lz4 to compress the images created in the docker container.

## Notes:

The Dockerfile-ubuntu-19.10 Dockerfile assumes that the remaining requirements to build the software are a subset of the requirements for building the ubuntu package linux-image-raspi2. If that package is removed at some point or there is a new package that supersedes that, that "apt-get build-dep -y linux-image-raspi2" line in the Dockerfile should be replaced or modified accordingly.
