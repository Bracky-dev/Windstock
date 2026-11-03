#pragma once
#include <string>
#include <vector>
#include "guest.h"

namespace wst {

struct Module {
    std::string name;
    gaddr base = 0;            // where PT_LOAD p_vaddr 0 landed
    u32 span = 0;
    u32 text_end = 0;          // end of the executable PT_LOAD (module-relative)
    gaddr dynamic = 0;
    gaddr strtab = 0;
    gaddr symtab = 0;
    u32 syment = 16;
    u32 nsyms = 0;
    gaddr init = 0;
    gaddr init_array = 0;
    u32 init_array_sz = 0;
    gaddr exidx = 0;
    u32 exidx_count = 0;
    std::vector<std::string> needed;
    bool inited = false;

    const char* str(u32 off) const { return HS(strtab + off); }
    // st_value of the named exported (defined) symbol, with the thumb bit kept.
    bool find(const char* name, gaddr* out) const;
};

Module* elf_load(const char* path, const char* soname);   // maps + relocates, no init
Module* elf_find(const std::string& soname);
void elf_run_init(Module* m);
gaddr elf_resolve_entry(Module* m, const char* sym);      // address with thumb bit
std::string describe_addr(gaddr a);
bool is_guest_code(gaddr a);                              // inside some module's executable segment
bool exidx_for(gaddr pc, gaddr* base, u32* count);

}  // namespace wst
