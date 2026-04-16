1. Download the kernel sources from google
   ```
   repo init -u https://android.googlesource.com/kernel/manifest -b android-gs-lynx-6.1-android16 --depth=1;
   repo sync -c --no-tags --no-clone-bundle
   ```
   (still takes around 46GB)
2. Download the shell scripts on the folder and run `extract_lynx.sh` (ai slop)
3. Download the firmware for pixel
4. Run `pmbootstrap init`, answer the questions (will create a new port) and give it the boot.img
5. Copy the folder's APKBUILD to relevant locations in `~/.local/var/pmbootstrap/cache_git/pmaports/device/downstream/*-google-lynx/` (don't worry, these are not accurate either)
6. Run `package_lynx.sh` (ai again)
7. Run
   ```
   pmbootsrap checksum device-google-lynx
   pmbootsrap build device-google-lynx
   pmbootsrap checksum linux-google-lynx
   pmbootsrap build linux-google-lynx
   ```
8. Make it work (search "pixel sbu usbc" and buy a uart adapter)
9. Run `pmbootstrap install`
### Flashing
Unlock your pixel (Will reset device): Go to developer options, enable "OEM unlocking",

10. Boot to fastboot (adb reboot fastboot or power + vol. down from powered off state) and:
    ```
    fastboot flashing unlock
    fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img # Use the path of vbmeta from step 3
    ```
    
11. Flash pmos
    ```
    pmbootstrap flasher flash_rootfs
    pmbootstrap flasher flash_kernel
    ```
Enjoy a bootloop because step 8 was probably not done
