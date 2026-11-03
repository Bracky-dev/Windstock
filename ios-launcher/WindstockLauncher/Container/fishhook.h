// fishhook -- dynamically rebind symbols in Mach-O binaries at runtime.
// Copyright (c) 2013, Facebook, Inc.  BSD 3-Clause (see LICENSE-fishhook.txt).
#ifndef fishhook_h
#define fishhook_h

#include <stddef.h>
#include <stdint.h>
#include <mach-o/loader.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding {
  const char *name;
  void *replacement;
  void **replaced;
};

// Rebind `name` in every image already loaded (and in images loaded later).
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

// Rebind `name` in exactly one image. This is what the container uses: the
// guest must see the hooked UIApplicationMain/getaddrinfo, the launcher must
// not.
int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel);

#ifdef __cplusplus
}
#endif
#endif
