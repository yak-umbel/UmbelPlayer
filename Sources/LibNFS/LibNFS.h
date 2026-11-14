// libnfs's interface, as the module `LibNFS`.
//
// The headers are libnfs's own, in UmbelNFS.framework under Binaries/ (built
// by Tools/BuildNetwork), found through the framework search path. The build
// changes only how they include each other, from <nfsc/…> to the framework's
// <UmbelNFS/…>, in its copies.
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <UmbelNFS/libnfs.h>
