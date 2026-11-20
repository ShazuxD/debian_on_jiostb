# Run Debian on JioSTB(JHSB200V5)[S905X2]

**Only for JHSB200V5 (franklin_skyworth)**

## What works
1. You can run debian alongside having JioOS installed.
2. Systemd support (Pid 1).
3. It runs on stock linux kernel `4.9.269` and kernel can't be upgraded.
4. If you want to check if something works at kernel level check `/proc/config.gz`.

### Requirements
1. JioSTB `JHSB200V5` running firmware `11.3.46`.
2. Unlocked Bootloader.
3. Magisk Installed.
4. Debian/Ubuntu/Linux or WSL2 running them.

# Generate Debian RootFS
1. Clone this repo.
   
2. Install Deps.
   ```bash
   sudo apt update
   apt install debootstrap qemu-user-static binfmt-support tar kmod
   ```
3. Edit `config.txt` accordingly.

4. Build RootFS.
   ```bash
   sudo ./setup-tarball.sh
   ```
   It uses default `config.txt` from repo you can provide it another config as well.
   ```bash
   sudo ./setup-tarball.sh [config.txt]
   ```
   
5. Now you will get `debian-arm64.tar.gz`.

# Copy debian-arm64.tar.gz
1. Connect to JioSTB with adb.
 
2. Move `debian-arm64.tar.gz` to setupbox (/sdcard)
   ```bash
   adb push debian-arm64.tar.gz /sdcard
   ```
   
3. Make sure android shell has su permissions.

4. Extract `debian-arm64.tar.gz` to /data/debian

5. Run
   ```bash
   adb shell su -c "mkdir -p /data/debian"
   adb shell su -c "tar -xpf /sdcard/debian-arm64.tar.gz -C /data/debian"
   ```

# Flash modified Recovery
1. This is modified stock recovery.
2. [Download it from here!](https://github.com/ShazuxD/debian_on_jiostb/releases).
3. Backup Stock recovery.
   ```bash
   adb shell su -c "dd if=/dev/block/by-name/recovery of=/sdcard/stock-recovery.img"
   adb pull /sdcard/stock-recovery.img
   ```
4. Flash Recovery.
   ```bash
   adb shell su -c "dd if=/sdcard/debian-recovery.img of=/dev/block/by-name/recovery bs=4096"
   ```

# StartUP

1. By default it will not boot into debian.
   
2. To boot into debian.
   ```bash
   adb shell su -c "touch /data/linux_boot"
   adb reboot recovery
   ```
   
3. Now it will boot into debian.

4. Connect it to ssh, use port and ip from your config.txt.
   ```bash
   ssh -p 2222 root@192.168.29.250
   ```

# Post Setup
1. Inside Debian, Run.
   ```bash
   mkuser yournewuser
   ```
2. Then you can directly log into user instead of root.

# How to Exit / Enter Again

1. Running `reboot` from terminal directly bootd into stock recovery.
2. Unplug Power to boot into JioOS.
3. To boot into debian, Run.
      ```bash
   adb shell su -c "touch /data/linux_boot"
   adb reboot recovery
   ```
4. `/data/linux_boot` is a trigger to boot into debian, it is wiped after debian boots, So you have to set again to boot back to Debian.


# Others

## Half Baked Gpu baked Weston GUI support with hdmi
1. It may not be fully stable
 [ShazuxD/mali-wayland-fakedrm](https://github.com/ShazuxD/mali-wayland-fakedrm)
