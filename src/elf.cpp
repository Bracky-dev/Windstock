// Minimal ELF32 ARM shared-object loader: map PT_LOAD, walk PT_DYNAMIC,
// apply REL relocations, bind imports to other modules or host thunks.
#include "elf.h"
#include "cpu.h"

#include <cstdio>
#include <cstring>
#include <vector>

namespace wst {

// ---- ELF32 on-disk types ----
#pragma pack(push, 1)
struct Ehdr { u8 ident[16]; u16 type, machine; u32 version, entry, phoff, shoff, flags;
              u16 ehsize, phentsize, phnum, shentsize, shnum, shstrndx; };
struct Phdr { u32 type, offset, vaddr, paddr, filesz, memsz, flags, align; };
struct Dyn  { s32 tag; u32 val; };
struct Sym  { u32 name, value, size; u8 info, other; u16 shndx; };
struct Rel  { u32 offset, info; };
#pragma pack(pop)

enum { PT_LOAD = 1, PT_DYNAMIC = 2, PT_ARM_EXIDX = 0x70000001 };
enum { DT_NEEDED=1, DT_PLTRELSZ=2, DT_PLTGOT=3, DT_HASH=4, DT_STRTAB=5, DT_SYMTAB=6,
       DT_REL=17, DT_RELSZ=18, DT_RELENT=19, DT_SYMENT=11, DT_INIT=12,
       DT_PLTREL=20, DT_JMPREL=23, DT_INIT_ARRAY=25, DT_INIT_ARRAYSZ=27,
       DT_GNU_HASH=0x6ffffef5 };
enum { R_ARM_ABS32=2, R_ARM_GLOB_DAT=21, R_ARM_JUMP_SLOT=22, R_ARM_RELATIVE=23, R_ARM_IRELATIVE=160 };

static std::vector<Module*> g_mods;

Module* elf_find(const std::string& soname) {
    for (auto* m : g_mods) if (m->name == soname) return m;
    return nullptr;
}

bool is_guest_code(gaddr a) {
    for (auto* m : g_mods) if (a >= m->base && a < m->base + m->text_end) return true;
    return false;
}

std::string describe_addr(gaddr a) {
    for (auto* m : g_mods)
        if (a >= m->base && a < m->base + m->span) {
            char buf[256];
            snprintf(buf, sizeof buf, "%s+0x%x", m->name.c_str(), a - m->base);
            return buf;
        }
    char buf[32]; snprintf(buf, sizeof buf, "0x%08x", a); return buf;
}

bool exidx_for(gaddr pc, gaddr* base, u32* count) {
    for (auto* m : g_mods)
        if (pc >= m->base && pc < m->base + m->span && m->exidx) {
            *base = m->exidx; *count = m->exidx_count; return true;
        }
    return false;
}

bool Module::find(const char* want, gaddr* out) const {
    for (u32 i = 0; i < nsyms; ++i) {
        const Sym* s = HP<Sym>(symtab + i * syment);
        if (s->shndx == 0) continue;                 // undefined
        if (strcmp(str(s->name), want) == 0) { *out = base + s->value; return true; }
    }
    return false;
}

// Resolve a symbol index referenced by a relocation in module m.
static bool resolve_sym(Module* m, u32 symidx, gaddr* out, bool* is_func) {
    const Sym* s = HP<Sym>(m->symtab + symidx * m->syment);
    const char* name = m->str(s->name);
    int type = s->info & 0xf;
    if (s->shndx != 0) {                             // defined here
        *out = m->base + s->value;
        *is_func = (type == 2 /*FUNC*/ || type == 10 /*IFUNC*/);
        return true;
    }
    // defined in another loaded module?
    for (auto* o : g_mods) {
        if (o == m) continue;
        gaddr v;
        if (o->find(name, &v)) { *out = v; *is_func = true; return true; }
    }
    // host-provided
    bool obj = (type == 1 /*OBJECT*/);
    *out = thunk_for_import(name, obj);
    *is_func = !obj;
    return true;
}

static void apply_rel(Module* m, gaddr rel, u32 size, const char* what) {
    u32 n = size / sizeof(Rel);
    for (u32 i = 0; i < n; ++i) {
        const Rel* r = HP<Rel>(rel + i * sizeof(Rel));
        u32 type = r->info & 0xff;
        u32 symidx = r->info >> 8;
        gaddr where = m->base + r->offset;
        switch (type) {
            case R_ARM_RELATIVE:
                wr32(where, rd32(where) + m->base);
                break;
            case R_ARM_GLOB_DAT:
            case R_ARM_JUMP_SLOT: {
                gaddr v; bool fn;
                if (!resolve_sym(m, symidx, &v, &fn)) fatal("%s: unresolved sym %u", what, symidx);
                wr32(where, v);
                break;
            }
            case R_ARM_ABS32: {
                gaddr v; bool fn;
                resolve_sym(m, symidx, &v, &fn);
                wr32(where, rd32(where) + v);
                break;
            }
            case R_ARM_IRELATIVE:
                // resolver returns the real address; run it as guest code.
                wr32(where, u32(call_guest(rd32(where), {})));
                break;
            default:
                fatal("%s: unhandled reloc type %u at %08x", what, type, where);
        }
    }
}

static u32 count_syms_gnu(gaddr gnu_hash, gaddr symtab, u32 syment) {
    u32 nbuckets = rd32(gnu_hash);
    u32 symoffset = rd32(gnu_hash + 4);
    u32 bloom_size = rd32(gnu_hash + 8);
    gaddr buckets = gnu_hash + 16 + bloom_size * 4;   // ELF32: 32-bit bloom words
    gaddr chain = buckets + nbuckets * 4;
    u32 last = 0;
    for (u32 i = 0; i < nbuckets; ++i) { u32 b = rd32(buckets + i * 4); if (b > last) last = b; }
    if (last < symoffset) return symoffset;
    for (;;) {
        u32 h = rd32(chain + (last - symoffset) * 4);
        ++last;
        if (h & 1) break;
    }
    (void)symtab; (void)syment;
    return last;
}

Module* elf_load(const char* path, const char* soname) {
    FILE* f = fopen(path, "rb");
    if (!f) fatal("cannot open %s", path);
    fseek(f, 0, SEEK_END);
    long fsz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<u8> file(fsz);
    if (fread(file.data(), 1, fsz, f) != size_t(fsz)) fatal("short read %s", path);
    fclose(f);

    auto* eh = reinterpret_cast<Ehdr*>(file.data());
    if (memcmp(eh->ident, "\x7f""ELF", 4) != 0 || eh->ident[4] != 1 /*ELFCLASS32*/ || eh->machine != 40 /*EM_ARM*/)
        fatal("%s is not an ARM32 ELF", path);

    // span
    u32 lo = ~0u, hi = 0;
    auto* ph = reinterpret_cast<Phdr*>(file.data() + eh->phoff);
    for (int i = 0; i < eh->phnum; ++i)
        if (ph[i].type == PT_LOAD) {
            lo = std::min(lo, ph[i].vaddr & ~0xFFFu);
            hi = std::max(hi, ph[i].vaddr + ph[i].memsz);
        }
    u32 span = (hi - lo + 0xFFF) & ~0xFFFu;

    auto* m = new Module();
    m->name = soname;
    m->base = va_alloc(span);
    m->span = span;
    if (m->base < lo) fatal("load base %08x below min vaddr %08x", m->base, lo);
    // place segments
    for (int i = 0; i < eh->phnum; ++i) {
        if (ph[i].type == PT_LOAD) {
            memcpy(H(m->base + ph[i].vaddr), file.data() + ph[i].offset, ph[i].filesz);
            if (ph[i].flags & 1) m->text_end = std::max(m->text_end, ph[i].vaddr + ph[i].filesz);
        }
        else if (ph[i].type == PT_DYNAMIC)
            m->dynamic = m->base + ph[i].vaddr;
        else if (ph[i].type == PT_ARM_EXIDX) {
            m->exidx = m->base + ph[i].vaddr;
            m->exidx_count = ph[i].memsz / 8;
        }
    }

    // walk dynamic
    gaddr rel = 0, jmprel = 0, gnu_hash = 0, hash = 0;
    u32 relsz = 0, pltrelsz = 0;
    for (gaddr d = m->dynamic; ; d += sizeof(Dyn)) {
        const Dyn* dyn = HP<Dyn>(d);
        if (dyn->tag == 0) break;
        switch (dyn->tag) {
            case DT_STRTAB: m->strtab = m->base + dyn->val; break;
            case DT_SYMTAB: m->symtab = m->base + dyn->val; break;
            case DT_SYMENT: m->syment = dyn->val; break;
            case DT_REL: rel = m->base + dyn->val; break;
            case DT_RELSZ: relsz = dyn->val; break;
            case DT_JMPREL: jmprel = m->base + dyn->val; break;
            case DT_PLTRELSZ: pltrelsz = dyn->val; break;
            case DT_INIT: m->init = m->base + dyn->val; break;
            case DT_INIT_ARRAY: m->init_array = m->base + dyn->val; break;
            case DT_INIT_ARRAYSZ: m->init_array_sz = dyn->val; break;
            case DT_HASH: hash = m->base + dyn->val; break;
            case DT_GNU_HASH: gnu_hash = m->base + dyn->val; break;
            case DT_NEEDED: break;  // resolved after strtab known (below)
        }
    }
    // second pass for DT_NEEDED now strtab is known
    for (gaddr d = m->dynamic; ; d += sizeof(Dyn)) {
        const Dyn* dyn = HP<Dyn>(d);
        if (dyn->tag == 0) break;
        if (dyn->tag == DT_NEEDED) m->needed.push_back(m->str(dyn->val));
    }

    if (hash) m->nsyms = rd32(hash + 4);                    // nchain
    else if (gnu_hash) m->nsyms = count_syms_gnu(gnu_hash, m->symtab, m->syment);
    else fatal("%s has no symbol hash", soname);

    logf("[elf] %s base=%08x span=%uK syms=%u rel=%u/%u needed=%zu",
         soname, m->base, span >> 10, m->nsyms, relsz / 8, pltrelsz / 8, m->needed.size());

    g_mods.push_back(m);
    if (rel) apply_rel(m, rel, relsz, "rel");
    if (jmprel) apply_rel(m, jmprel, pltrelsz, "jmprel");
    return m;
}

void elf_run_init(Module* m) {
    if (m->inited) return;
    m->inited = true;
    if (m->init) call_guest(m->init, {});
    for (u32 i = 0; i < m->init_array_sz / 4; ++i) {
        gaddr fn = rd32(m->init_array + i * 4);
        if (fn && fn != 0xFFFFFFFFu) {
            VLOG("[init] %s init_array[%u] -> %s", m->name.c_str(), i, describe_addr(fn & ~1u).c_str());
            call_guest(fn, {});
        }
    }
}

gaddr elf_resolve_entry(Module* m, const char* sym) {
    gaddr v;
    if (!m->find(sym, &v)) fatal("%s: no export '%s'", m->name.c_str(), sym);
    // find() strips the thumb bit (adds base to st_value). Re-apply the bit from st_value.
    for (u32 i = 0; i < m->nsyms; ++i) {
        const Sym* s = HP<Sym>(m->symtab + i * m->syment);
        if (s->shndx && strcmp(m->str(s->name), sym) == 0)
            return m->base + s->value;   // keeps bit0 (thumb)
    }
    return v;
}

}  // namespace wst
