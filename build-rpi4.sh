#!/bin/bash -e

# This script is executed within the container as root. The resulting image &
# logs are written to /output after a succesful build.  These directories are 
# mounted as docker volumes to allow files to be exchanged between the host and 
# the container.

# Logging Setup
TMPLOG=/tmp/build.log
touch $TMPLOG
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>$TMPLOG 2>&1




## Setup
# Set Time Stamp
now=`date +"%m_%d_%Y_%H%M"`
# Use ccache
export PATH=/usr/lib/ccache:$PATH
# Make read-write copy of source folder
mkdir -p /build
cp -a /source-ro /build/source
cd /build/source



branch=rpi-4.19.y
ubuntu_image_url="http://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/eoan-preinstalled-server-arm64+raspi3.img.xz"





checkfor_and_download_ubuntu_image () {
    cd /build/source
    if [ ! -f /eoan-preinstalled-server-arm64+raspi3.img.xz ]; then
        echo "Downloading daily-preinstalled eoan ubuntu-server raspi3 image."
        wget $ubuntu_image_url
        echo "Extracting image."
        xzcat eoan-preinstalled-server-arm64+raspi3.img.xz > \
        eoan-preinstalled-server-arm64+raspi4.img
    else
        echo "Extracting image."
        xzcat /eoan-preinstalled-server-arm64+raspi3.img.xz > \
        eoan-preinstalled-server-arm64+raspi4.img
    fi
    }

mount_image () {
    cd /build/source
    echo "Mounting image."
    kpartx -av eoan-preinstalled-server-arm64+raspi4.img
    mount /dev/mapper/loop0p2 /mnt
    mount /dev/mapper/loop0p1 /mnt/boot/firmware
}

get_rpi_firmware () {
    cd /build/source
    echo "Downloading current RPI firmware."
    git clone --depth=1 https://github.com/Hexxeh/rpi-firmware
    cp rpi-firmware/bootcode.bin /mnt/boot/firmware/
    cp rpi-firmware/*.elf /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dtb /mnt/boot/firmware/
    cp rpi-firmware/overlays/*.dtbo /mnt/boot/firmware/overlays/
}

get_kernel_src () {
    echo "Downloading $branch RPI kernel source."
    cd /build/source
    git clone --depth=1 -b $branch https://github.com/raspberrypi/linux.git rpi-linux
}

build_kernel () {
    echo "Building $branch kernel."
    cd /build/source/rpi-linux
    #git checkout origin/rpi-4.19.y # change the branch name for newer versions
    mkdir kernel-build

    make O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig
    
    cd kernel-build
    # Use kernel config modification script from sakaki- found at 
    # https://github.com/sakaki-/bcm2711-kernel-bis
    #/build/source/conform_config.sh
    #make O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    #cd ..

    make -j4 O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    KERNEL_VERSION=`cat ./kernel-build/include/generated/utsrelease.h | \
    sed -e 's/.*"\(.*\)".*/\1/'`
    sudo make -j4 O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    DEPMOD=echo  INSTALL_MOD_PATH=./kernel-install/ modules_install
    cd ..
}

install_kernel () {
    echo "Copying compiled ${KERNEL_VERSION} kernel to image."
    cd /build/source
    # Ubuntu defaults to using uBoot, which doesn't work yet for RPI4.
    # Replacee uBoot with kernel.
    cp rpi-linux/kernel-build/arch/arm64/boot/Image /mnt/boot/firmware/kernel8.img
    # Once uBoot works, it should be able to use the standard raspberry pi boot
    # script to boot the compressed kernel on arm64, so we copy this in anyways.
    cp rpi-linux/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/vmlinuz-${KERNEL_VERSION}
    cp rpi-linux/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/firmware/vmlinuz
    cp rpi-linux/kernel-build/.config /mnt/boot/config-${KERNEL_VERSION}

    echo "Copying compiled ${KERNEL_VERSION} modules to image."
    cp -avr rpi-linux/kernel-build/kernel-install/lib/modules/${KERNEL_VERSION} \
    /mnt/usr/lib/modules/
    rm  -rf /mnt/usr/lib/modules/${KERNEL_VERSION}/build 
    mv -f rpi-linux/kernel-build/kernel-install/lib/modules/${KERNEL_VERSION}/build \
    /mnt/usr/src/linux-headers-${KERNEL_VERSION}
    cd /mnt/usr/src
    ln -s ../lib/modules/${KERNEL_VERSION} linux-headers-${KERNEL_VERSION}
    cd /mnt/usr/lib/modules/${KERNEL_VERSION}/
    ln -s ../../../linux-headers-${KERNEL_VERSION} build

    cd /build/source
    echo "Copying compiled ${KERNEL_VERSION} dtbs & dtbos to image."
    cp rpi-linux/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/boot/firmware/
    cp rpi-linux/kernel-build/arch/arm64/boot/dts/overlays/*.dtbo \
    /mnt/boot/firmware/overlays/
    cp rpi-linux/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb \
    /mnt/etc/flash-kernel/dtbs/
    if ! grep -qs 'kernel8.bin' /mnt/boot/firmware/config.txt
        then sed -i -r 's/kernel8.bin/kernel8.img/' /mnt/boot/firmware/config.txt
    fi
}

install_armstub8-gic () {
    echo "Installing RPI4 armstub8-gic source"
    cd /build/source
    git clone --depth=1 https://github.com/raspberrypi/tools.git rpi-tools
    cd rpi-tools/armstubs
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- armstub8-gic.bin
    cd ../..
    cp rpi-tools/armstubs/armstub8-gic.bin /mnt/boot/firmware/armstub8-gic.bin
}

install_non-free_firmware () {
    echo "Installing non-free firmware.."
    cd /build/source
    git clone --depth=1 https://github.com/RPi-Distro/firmware-nonfree firmware-nonfree
    cp -avf firmware-nonfree/* /mnt/usr/lib/firmware
}


configure_rpi_config_txt () {
    echo "Making /boot/firmware/config.txt modifications."
    echo "armstub=armstub8-gic.bin" >> /mnt/boot/firmware/config.txt
    echo "enable_gic=1" >> /mnt/boot/firmware/config.txt
    if ! grep -qs 'arm_64bit=1' /mnt/boot/firmware/config.txt
        then echo "arm_64bit=1" >> /mnt/boot/firmware/config.txt
    fi
}

install_rpi_userland () {
    echo "Installing Raspberry Pi userland source."
    cd /build/source
    git clone --depth=1 https://github.com/raspberrypi/userland
    mkdir -p /mnt/opt/vc
    cd userland/
    CROSS_COMPILE=aarch64-linux-gnu- ./buildme --aarch64 /mnt
    echo '/opt/vc/lib' > /mnt/etc/ld.so.conf.d/vc.conf 
    mkdir -p /mnt/etc/environment.d
    echo -e '# /etc/env.d/00vcgencmd\n\
    # Do not edit this file\n\
    \n\
    PATH="/opt/vc/bin:/opt/vc/sbin"\n\
    ROOTPATH="/opt/vc/bin:/opt/vc/sbin"\n\
    LDPATH="/opt/vc/lib"' \
    > /mnt/etc/environment.d/10-vcgencmd.conf
    cd ..
}

modify_wifi_firmware () {
    echo "Modifying wireless firmware."
    # as per https://andrei.gherzan.ro/linux/raspbian-rpi4-64/
    if ! grep -qs 'boardflags3=0x44200100' \
    /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
        then sed -i -r 's/0x48200100/0x44200100/' \
        /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
    fi
}

install_first_start_cleanup_script () {
    echo "Creating first start cleanup script"
    echo -e '#!/bin/sh -e\n\
    # 1st Boot Cleanup Script\n#\n\
    # Print the IP address\n\
    _IP=$(hostname -I) || true\n\
    if [ "$_IP" ]; then\n\
      printf "My IP address is %s\n" "$_IP"\n\
    fi\n\
    #\n\
    sleep 30\n\
    /usr/bin/apt update && \
    /usr/bin/apt remove linux-image-raspi2 linux-raspi2 \
    flash-kernel initramfs-tools -y\n\
    /usr/bin/apt install wireless-tools wireless-regdb crda -y\n\
    rm /etc/rc.local\n\n\
    exit 0' > /mnt/etc/rc.local
    chmod +x /mnt/etc/rc.local
}

unmount_image () {
    echo "unmounting modified image"
    cd /build/source
    umount /mnt/boot/firmware
    umount /mnt
    kpartx -dv eoan-preinstalled-server-arm64+raspi4.img
}

export_compressed_image () {
    echo "Compressing image with lz4 & copying out of container."
    cd /build/source 
    chown -R $USER:$GROUP /build
    compresscmd="lz4 eoan-preinstalled-server-arm64+raspi4.img \
    /output/eoan-preinstalled-server-arm64+raspi4-${KERNEL_VERSION}_${now}.img.lz4"
    echo $compresscmd
    lz4 eoan-preinstalled-server-arm64+raspi4.img \
    /output/eoan-preinstalled-server-arm64+raspi4-${KERNEL_VERSION}_${now}.img.lz4
}



# copy_image_out () {
#     # Copy packages to output dir with user's permissions
#     chown -R $USER:$GROUP /build
#     echo "Copying image out of container."
#     cp -a /build/source/*.lz4 /output/
# }

export_log () {
    cp $TMPLOG /output/build-log-${KERNEL_VERSION}_${now}.log
}



checkfor_and_download_ubuntu_image 
mount_image
get_rpi_firmware
get_kernel_src
# KERNEL_VERSION is set here:
build_kernel
install_kernel
install_armstub8-gic
install_non-free_firmware
configure_rpi_config_txt
install_rpi_userland
modify_wifi_firmware 
install_first_start_cleanup_script
unmount_image
export_compressed_image
export_log
ls -l /output
read -p "Press [Enter] key to quit and delete container"
