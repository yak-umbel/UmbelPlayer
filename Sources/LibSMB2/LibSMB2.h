// libsmb2's interface, as the module `LibSMB2`.
//
// The headers are libsmb2's own, in UmbelSMB2.framework under Binaries/ (built
// by Tools/BuildNetwork), found through the framework search path. The build
// changes only how they include each other, from <smb2/…> to the framework's
// <UmbelSMB2/…>, in its copies. libsmb2.h expects what it uses to have been
// included before it, as libsmb2's own programs do; that is done here.
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>
#include <UmbelSMB2/smb2.h>
#include <UmbelSMB2/libsmb2.h>
