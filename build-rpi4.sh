#!/bin/bash -e

# This script is executed within the container as root. The resulting image &
# logs are written to /output after a succesful build.  These directories are 
# mounted as docker volumes to allow files to be exchanged between the host and 
# the container.

branch=rpi-4.19.y
kernelgitrepo="https://github.com/raspberrypi/linux.git"
# This should be the image we want to modify.
ubuntu_image="eoan-preinstalled-server-arm64+raspi3.img.xz"
ubuntu_image_url="http://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/${ubuntu_image}"
# This is the base name of the image we are creating.
new_image="eoan-preinstalled-server-arm64+raspi4"


# Set Time Stamp
now=`date +"%m_%d_%Y_%H%M"`

# Logging Setup
TMPLOG=/tmp/build.log
touch $TMPLOG
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>$TMPLOG 2>&1

# Use ccache
PATH=/usr/lib/ccache:$PATH
# Create work directory
mkdir -p /build/source
#cp -a /source-ro/ /build/source
#cd /build/source





checkfor_and_download_ubuntu_image () {
    echo "Checking for downloaded ${ubuntu_image}"
    cd /build/source
    if [ ! -f /${ubuntu_image} ]; then
        echo "Downloading ${ubuntu_image}"
        wget $ubuntu_image_url -O $ubuntu_image
    else
        ln -s /$ubuntu_image /build/source/
    fi
    echo "Extracting: ${ubuntu_image} to ${new_image}.img"
    xzcat /$ubuntu_image > $new_image.img
    }

mount_image () {
    echo "* Clearing existing loopback mounts."
    losetup -d /dev/loop0
    dmsetup remove_all
    losetup -a
    cd /build/source
    echo "Mounting: ${new_image}.img"
    kpartx -av ${new_image}.img
    mount /dev/mapper/loop0p2 /mnt
    mount /dev/mapper/loop0p1 /mnt/boot/firmware
}

setup_arm64_chroot () {
    echo "* Setup arm64 chroot"
    cp /usr/bin/qemu-aarch64-static /mnt/usr/bin
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    remove flash-kernel initramfs-tools -y"
    #remove linux-image-raspi2 \
    #linux-headers-raspi2 flash-kernel initramfs-tools -y"
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    update
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    install -d gcc make flex bison libssl-dev -y
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    install gcc make flex bison libssl-dev -y"
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    autoclean -y"   
}

get_rpi_firmware () {
    cd /build/source
    echo "* Downloading current RPI firmware."
    git clone --depth=1 https://github.com/Hexxeh/rpi-firmware
    cp rpi-firmware/bootcode.bin /mnt/boot/firmware/
    cp rpi-firmware/*.elf /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dtb /mnt/boot/firmware/
    cp rpi-firmware/overlays/*.dtbo /mnt/boot/firmware/overlays/
}

get_kernel_src () {
    echo "* Downloading $branch kernel source."
    cd /build/source
    git clone --depth=1 -b $branch $kernelgitrepo rpi-linux
    kernelrev=`cd /build/source/rpi-linux ; git rev-parse HEAD`
}

build_kernel () {
    echo "* Building $branch kernel."
    cd /build/source/rpi-linux
    #git checkout origin/rpi-4.19.y # change the branch name for newer versions
    mkdir /build/source/kernel-build
    

    make O=/build/source/kernel-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig
    
    #cd /build/source/kernel-build
    # Use kernel config modification script from sakaki- found at 
    # https://github.com/sakaki-/bcm2711-kernel-bis
    #/build/source/conform_config.sh
    #make O=./build/source/kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    #cd ..

    cd /build/source/rpi-linux
    make -j`nproc` O=/build/source/kernel-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
    KERNEL_VERSION=`cat /build/source/kernel-build/include/generated/utsrelease.h | \
    sed -e 's/.*"\(.*\)".*/\1/'`
    
    mkdir /build/source/kernel-install
    sudo make -j`nproc` O=/build/source/kernel-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    DEPMOD=echo  INSTALL_MOD_PATH=/build/source/kernel-install modules_install
}

install_kernel () {
    echo "* Copying compiled ${KERNEL_VERSION} kernel to image."
    df -h
    cd /build/source
    # Ubuntu defaults to using uBoot, which doesn't work yet for RPI4.
    # Replacee uBoot with kernel.
    cp /build/source/kernel-build/arch/arm64/boot/Image /mnt/boot/firmware/kernel8.img
    # Once uBoot works, it should be able to use the standard raspberry pi boot
    # script to boot the compressed kernel on arm64, so we copy this in anyways.
    cp /build/source/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/vmlinuz-${KERNEL_VERSION}
    cp /build/source/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/firmware/vmlinuz
    cp /build/source/kernel-build/.config /mnt/boot/config-${KERNEL_VERSION}

    echo "* Copying compiled ${KERNEL_VERSION} modules to image."
    rm  -rf /build/source/kernel-install/lib/modules/build
    cp -avr /build/source/kernel-install/lib/modules/* \
    /mnt/usr/lib/modules/
    rm  -rf /mnt/usr/lib/modules/${KERNEL_VERSION}/build 

    echo "* Copying compiled ${KERNEL_VERSION} dtbs & dtbos to image."
    cp /build/source/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/boot/firmware/
    cp /build/source/kernel-build/arch/arm64/boot/dts/overlays/*.dtbo \
    /mnt/boot/firmware/overlays/
    cp /build/source/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb \
    /mnt/etc/flash-kernel/dtbs/
    if ! grep -qs 'kernel8.bin' /mnt/boot/firmware/config.txt
        then sed -i -r 's/kernel8.bin/kernel8.img/' /mnt/boot/firmware/config.txt
    fi
}

install_kernel_headers () {
    echo "* Copying ${KERNEL_VERSION} kernel headers to image."
    mkdir -p /mnt/build
    mount -o bind /build     /mnt/build
    mkdir -p /mnt/usr/src/linux-headers-${KERNEL_VERSION}

    cp /build/source/kernel-build/.config /build/source/rpi-linux/
    cp /build/source/kernel-build/{modules.builtin,modules.order,Module.symvers,System.map,.config} /mnt/usr/src/linux-headers-${KERNEL_VERSION}/

    echo "* Regenerating broken cross-compile module installation infrastructure."
    # Cross-compilation of kernel wreaks havoc with building out of kernel modules
    # later, so let's fix this with natively compiled module tools.
    files=("scripts/recordmcount" "scripts/mod/modpost" \
        "scripts/basic/fixdep")
    for i in "${files[@]}"
    do
     rm /build/source/kernel-build/$i
    done
    #chroot /mnt /bin/bash -c "cd /build/source/rpi-linux ; \
    #make -j`nproc` O=/build/source/kernel-build mrproper"
    # cp /mnt/usr/src/linux-headers-${KERNEL_VERSION}/.config /build/source/kernel-build/
    # This step is expected to fail, but it does what is needed before it fails.
    chroot /mnt /bin/bash -c "cd /build/source/rpi-linux ; \
    make -j`nproc` O=/build/source/kernel-build modules_prepare || true"
    chroot /mnt /bin/bash -c "cd /build/source/rpi-linux ; \
    make -j`nproc` O=/build/source/kernel-build scripts_basic"
    chroot /mnt /bin/bash -c "cd /build/source/rpi-linux ; \
    make -j`nproc` O=/build/source/kernel-build scripts/recordmcount || true"
    chroot /mnt /bin/bash -c "cd /build/source/rpi-linux ; \
    make -j`nproc` O=/build/source/kernel-build scripts/mod/modpost || true"
    # Compilation tools no longer needed in image, so let's take them out to save space.
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    remove gcc bison flex make libssl-dev -y"
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    autoremove -y"
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    autoclean -y"
    find /build/source/rpi-linux -type f -name "*.c" -exec rm -rf {} \;
    mkdir -p /mnt/usr/src/linux-headers-${KERNEL_VERSION}
   # cp /build/source/kernel-build/.config /mnt/usr/src/linux-headers-${KERNEL_VERSION}/.config
   # cp /build/source/kernel-build/Module.symvers /mnt/usr/src/linux-headers-${KERNEL_VERSION}/  
   # cp /build/source/kernel-build/.config /build/source/rpi-linux/
   # cp /build/source/kernel-build/Module.symvers /build/source/rpi-linux/
   files=("scripts/recordmcount" "scripts/mod/modpost" \
        "scripts/basic/fixdep")
    for i in "${files[@]}"
    do
     mkdir -p `dirname /mnt/usr/src/linux-headers-${KERNEL_VERSION}/$i` && \
     cp /build/source/kernel-build/$i /mnt/usr/src/linux-headers-${KERNEL_VERSION}/$i
    done
   # cp /build/source/kernel-build/Module.symvers /mnt/usr/src/linux-headers-${KERNEL_VERSION}/
    cp -avf /build/source/rpi-linux/* /mnt/usr/src/linux-headers-${KERNEL_VERSION}/

   # mv /build/source/rpi-linux /build/root/usr/src/linux-headers-${KERNEL_VERSION}
   # cd /build/root
   # tar cvf - usr/ | lz4 -9 -BD - kernel-headers.tar.lz4
   # Don't fire error if this fails.
   # cp kernel-headers.tar.lz4 /mnt/ 2>/dev/null || :
}


install_armstub8-gic () {
    echo "* Installing RPI4 armstub8-gic source."
    cd /build/source
    git clone --depth=1 https://github.com/raspberrypi/tools.git rpi-tools
    cd rpi-tools/armstubs
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- armstub8-gic.bin
    cd ../..
    cp rpi-tools/armstubs/armstub8-gic.bin /mnt/boot/firmware/armstub8-gic.bin
}

install_non-free_firmware () {
    echo "* Installing non-free firmware."
    cd /build/source
    git clone --depth=1 https://github.com/RPi-Distro/firmware-nonfree firmware-nonfree
    cp -avf firmware-nonfree/* /mnt/usr/lib/firmware
}


configure_rpi_config_txt () {
    echo "* Making /boot/firmware/config.txt modifications."
    echo "armstub=armstub8-gic.bin" >> /mnt/boot/firmware/config.txt
    echo "enable_gic=1" >> /mnt/boot/firmware/config.txt
    if ! grep -qs 'arm_64bit=1' /mnt/boot/firmware/config.txt
        then echo "arm_64bit=1" >> /mnt/boot/firmware/config.txt
    fi
}

install_rpi_userland () {
    echo "* Installing Raspberry Pi userland source."
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
    echo "* Modifying wireless firmware."
    # as per https://andrei.gherzan.ro/linux/raspbian-rpi4-64/
    if ! grep -qs 'boardflags3=0x44200100' \
    /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
        then sed -i -r 's/0x48200100/0x44200100/' \
        /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
    fi
}

install_first_start_cleanup_script () {
    echo "* Creating first start cleanup script."
    echo -e '#!/bin/sh -e\n\
    # 1st Boot Cleanup Script\n#\n\
    # Print the IP address\n\
    _IP=$(hostname -I) || true\n\
    if [ "$_IP" ]; then\n\
      printf "My IP address is %s\n" "$_IP"\n\
    fi\n\
    #\n\
    #sleep 30\n\
    #/usr/bin/apt update && \
    #/usr/bin/apt remove linux-image-raspi2 linux-raspi2 \
    #flash-kernel initramfs-tools -y\n\
    #/usr/bin/apt install wireless-tools wireless-regdb crda lz4 git -y\n\
    #/usr/bin/apt upgrade -y\n\
    #cd /usr/src \n\
    #/usr/bin/git clone --depth=1 -b $branch $kernelgitrepo \
    #linux-headers-${KERNEL_VERSION}\n\
    #/usr/bin/git checkout $kernelrev\n\
    rm /etc/rc.local\n\n\
    exit 0' > /mnt/etc/rc.local
    chmod +x /mnt/etc/rc.local
}

cleanup_image () {
    echo "* Finishing image setup."
    cp /usr/bin/qemu-aarch64-static /mnt/usr/bin
    #mount -t proc proc     /mnt/proc/
    #mount -t sysfs sys     /mnt/sys/
    #mount -o bind /dev     /mnt/dev/
    #mount -o bind /dev/pts /mnt/dev/pts
    #chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    #remove linux-image-raspi2 linux-raspi2 \
    #flash-kernel initramfs-tools -y"
    #chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    #autoremove -y"
    #chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    #update"
    #apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    #update
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -d install wireless-tools wireless-regdb crda -y
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    install wireless-tools wireless-regdb crda -y"
    chroot /mnt /bin/bash -c "ln -s /usr/src/linux-headers-${KERNEL_VERSION} \
    /usr/lib/modules/${KERNEL_VERSION}/build"
    #mkdir -p /build/src/apt/archives
    #mkdir -p /build/src/apt/lists
    #dpkg --add-architecture arm64
    #apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    #remove linux-image-raspi2 linux-raspi2 \
    #flash-kernel initramfs-tools -y
    #apt-get -o Dir=/mnt -o APT::Architecture=arm64 autoclean -y
    #apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    #-o dir::cache::archives=/build/src/apt/archives \
    #update
    #-o dir::state::lists=/build/src/apt/lists \
    #update
    #apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    #-o dir::cache::archives=/build/src/apt/archives \
    #install wireless-tools wireless-regdb crda -y
    #-o dir::state::lists=/build/src/apt/lists \
    #install wireless-tools wireless-regdb crda -y
    #apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    #-o dir::cache::archives=/build/src/apt/archives \
    #-o dir::state::lists=/build/src/apt/lists \
    #upgrade -y
    #apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    #-o dir::cache::archives=/build/src/apt/archives \
    #-o dir::state::lists=/build/src/apt/lists \
    #autoclean -y
    
    #umount /mnt/proc
    #umount /mnt/sys
    #umount /mnt/dev/pts
    #umount /mnt/dev
}

remove_chroot () {
    echo "* Cleaning up arm64 chroot"
    chroot /mnt /bin/bash -c "/usr/bin/apt-get -o APT::Architecture=arm64 \
    autoclean -y"
    umount /mnt/build
    rm -f /mnt/build
    rm /mnt/usr/bin/qemu-aarch64-static
}

unmount_image () {
    echo "* Unmounting modified ${new_image}.img"
    sync
    umount /mnt/boot/firmware
    umount /mnt
    kpartx -dv /build/source/${new_image}.img
    losetup -d /dev/loop0
    dmsetup remove_all
}

export_compressed_image () {
    echo "* Compressing ${new_image} with lz4 and exporting"
    echo "  out of container to:"
    echo "${new_image}-${KERNEL_VERSION}_${now}.img.lz4"
    cd /build/source
    chown -R $USER:$GROUP /build
    compresscmd="lz4 ${new_image}.img \
    /output/${new_image}-${KERNEL_VERSION}_${now}.img.lz4"
    echo $compresscmd
    $compresscmd
}

export_log () {
    echo "* Build log at: build-log-${KERNEL_VERSION}_${now}.log"
    cat $TMPLOG > /output/build-log-${KERNEL_VERSION}_${now}.log
    chown $USER:$GROUP /output/build-log-${KERNEL_VERSION}_${now}.log
}



checkfor_and_download_ubuntu_image 
mount_image
setup_arm64_chroot
get_rpi_firmware
get_kernel_src
# KERNEL_VERSION is set here:
build_kernel
install_kernel
install_kernel_headers
install_armstub8-gic
install_non-free_firmware
configure_rpi_config_txt
install_rpi_userland
modify_wifi_firmware 
install_first_start_cleanup_script
cleanup_image
remove_chroot
unmount_image
export_compressed_image
export_log
rm $TMPLOG
ls -l /output
