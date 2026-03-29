### AnyKernel3 Ramdisk Mod Script
## Crimson RubyX kernel package

### AnyKernel setup
# global properties
properties() { '
kernel.string=Crimson RubyX for Xiaomi ruby/rubypro
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=ruby
device.name2=rubypro
device.name3=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching
. tools/ak3-core.sh;

# boot install
dump_boot;
write_boot;
