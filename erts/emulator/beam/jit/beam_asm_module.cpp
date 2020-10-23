/*
 * %CopyrightBegin%
 *
 * Copyright Ericsson AB 2020-2020. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * %CopyrightEnd%
 */

#include <algorithm>
#include <float.h>

#include "beam_asm.hpp"
using namespace asmjit;

static std::string getAtom(Eterm atom) {
    Atom *ap = atom_tab(atom_val(atom));
    return std::string((char *)ap->name, ap->len);
}

#ifdef BEAMASM_DUMP_SIZES
#    include <mutex>

typedef std::pair<Uint64, Uint64> op_stats;

static std::unordered_map<char *, op_stats> sizes;
static std::mutex size_lock;

extern "C" void beamasm_dump_sizes() {
    std::lock_guard<std::mutex> lock(size_lock);

    std::vector<std::pair<char *, op_stats>> flat(sizes.cbegin(), sizes.cend());
    double total_size = 0.0;

    for (const auto &op : flat) {
        total_size += op.second.second;
    }

    /* Sort instructions by total size, in descending order. */
    std::sort(
            flat.begin(),
            flat.end(),
            [](std::pair<char *, op_stats> &a, std::pair<char *, op_stats> &b) {
                return a.second.second > b.second.second;
            });

    for (const auto &op : flat) {
        fprintf(stderr,
                "%34s:\t%zu\t%f\t%zu\t%zu\r\n",
                op.first,
                op.second.second,
                op.second.second / total_size,
                op.second.first,
                op.second.first ? (op.second.second / op.second.first) : 0);
    }
}
#endif

BeamModuleAssembler::BeamModuleAssembler(BeamGlobalAssembler *ga,
                                         Eterm mod,
                                         unsigned num_labels)
        : BeamAssembler(getAtom(mod)) {
    this->ga = ga;
    this->mod = mod;

    labels.reserve(num_labels + 1);
    for (unsigned i = 1; i < num_labels; i++) {
        Label lbl;

#ifdef DEBUG
        std::string lblName = "label_" + std::to_string(i);
        lbl = a.newNamedLabel(lblName.data());
#else
        lbl = a.newLabel();
#endif

        labels[i] = lbl;
    }
}

BeamModuleAssembler::BeamModuleAssembler(BeamGlobalAssembler *ga,
                                         Eterm mod,
                                         unsigned num_labels,
                                         unsigned num_functions)
        : BeamModuleAssembler(ga, mod, num_labels) {
    codeHeader = a.newLabel();
    a.align(kAlignCode, 8);
    a.bind(codeHeader);

    embed_zeros(sizeof(BeamCodeHeader) +
                sizeof(ErtsCodeInfo *) * num_functions);

    floatMax = a.newLabel();
    a.align(kAlignCode, 8);
    a.bind(floatMax);
    double max = DBL_MAX;
    a.embed((char *)&max, sizeof(double));

    floatSignMask = a.newLabel();
    a.align(kAlignCode, 16); /* 128-bit aligned */
    a.bind(floatSignMask);
    uint64_t signMask = 0x7FFFFFFFFFFFFFFFul;
    a.embed((char *)&signMask, sizeof(double));

    /* Shared trampoline for function_clause errors, which can't jump straight
     * to `i_func_info_shared` due to size restrictions. */
    funcInfo = a.newLabel();
    a.align(kAlignCode, 8);
    a.bind(funcInfo);
    abs_jmp(ga->get_i_func_info_shared());

    /* Shared trampoline for yielding on function ingress. */
    funcYield = a.newLabel();
    a.align(kAlignCode, 8);
    a.bind(funcYield);
    abs_jmp(ga->get_i_test_yield_shared());

    /* Setup the early_nif/breakpoint trampoline. */
    genericBPTramp = a.newLabel();
    a.align(kAlignCode, 16);
    a.bind(genericBPTramp);
    {
        a.ret();

        a.align(kAlignCode, 16);
        abs_jmp(ga->get_call_nif_early());

        a.align(kAlignCode, 16);
        aligned_call(ga->get_generic_bp_local());
        a.ret();

        a.align(kAlignCode, 16);
        ASSERT(a.offset() - code.labelOffsetFromBase(genericBPTramp) == 16 * 3);
        aligned_call(ga->get_generic_bp_local());
        abs_jmp(ga->get_call_nif_early());
    }
}

BeamInstr *BeamModuleAssembler::getCode(unsigned label) {
    ASSERT(label < labels.size() + 1);
    return (BeamInstr *)getCode(labels[label]);
}

void BeamAssembler::embed_rodata(char *labelName,
                                 const char *buff,
                                 size_t size) {
    Label label = a.newNamedLabel(labelName);

    a.section(rodata);
    a.bind(label);
    a.embed(buff, size);
    a.section(code.textSection());
}

void BeamAssembler::embed_bss(char *labelName, size_t size) {
    Label label = a.newNamedLabel(labelName);

    /* Reuse rodata section for now */
    a.section(rodata);
    a.bind(label);
    embed_zeros(size);
    a.section(code.textSection());
}

void BeamAssembler::embed_zeros(size_t size) {
    static constexpr size_t buf_size = 16384;
    static const char zeros[buf_size] = {};

    while (size >= buf_size) {
        a.embed(zeros, buf_size);
        size -= buf_size;
    }

    if (size > 0) {
        a.embed(zeros, size);
    }
}

Label BeamModuleAssembler::embed_vararg_rodata(const std::vector<ArgVal> &args,
                                               int y_offset) {
    Label label = a.newLabel();

#if !defined(NATIVE_ERLANG_STACK)
    y_offset = CP_SIZE;
#endif

    a.section(rodata);
    a.bind(label);

    for (const ArgVal &arg : args) {
        union {
            BeamInstr as_beam;
            char as_char[1];
        } data;

        a.align(kAlignData, 8);
        switch (arg.getType()) {
        case TAG_x:
            data.as_beam = make_loader_x_reg(arg.getValue());
            a.embed(&data.as_char, sizeof(data.as_beam));
            break;
        case TAG_y:
            data.as_beam = make_loader_y_reg(arg.getValue() + y_offset);
            a.embed(&data.as_char, sizeof(data.as_beam));
            break;
        case TAG_q:
            make_word_patch(literals[arg.getValue()].patches);
            break;
        case TAG_f:
            a.embedLabel(labels[arg.getValue()]);
            break;
        case TAG_i:
        case TAG_u:
            /* Tagged immediate or untagged word. */
            data.as_beam = arg.getValue();
            a.embed(&data.as_char, sizeof(data.as_beam));
            break;
        default:
            ERTS_ASSERT(!"error");
        }
    }

    a.section(code.textSection());

    return label;
}

static void i_emit_nyi(char *msg) {
    erts_exit(ERTS_ERROR_EXIT, "NYI: %s\n", msg);
}

void BeamModuleAssembler::emit_i_nif_padding() {
    const size_t minimum_size = sizeof(UWord[BEAM_NATIVE_MIN_FUNC_SZ]);
    size_t prev_func_start, diff;

    prev_func_start = code.labelOffsetFromBase(labels[functions.back() + 1]);
    diff = a.offset() - prev_func_start;

    if (diff < minimum_size) {
        embed_zeros(minimum_size - diff);
    }
}

void BeamModuleAssembler::emit_i_breakpoint_trampoline() {
    /* This little prologue is used by nif loading and tracing to insert
     * alternative instructions. The call is filled with a relative call to a
     * trampoline in the module header and then the jmp target is zeroed so that
     * it effectively becomes a nop */
    byte flag = ERTS_ASM_BP_FLAG_NONE;
    Label next = a.newLabel();

    a.short_().jmp(next);

    /* We embed a zero byte here, which is used to flag whether to make an early
     * nif call, call a breakpoint handler, or both. */
    a.embed(&flag, sizeof(flag));

    if (genericBPTramp.isValid()) {
        a.call(genericBPTramp);
    } else {
        /* NIF or BIF stub; we're not going to use this trampoline as-is, but
         * we need to reserve space for it. */
        a.ud2();
    }

    a.align(kAlignCode, 8);
    a.bind(next);
    ASSERT((a.offset() - code.labelOffsetFromBase(currLabel)) ==
           BEAM_ASM_FUNC_PROLOGUE_SIZE);
}

void BeamModuleAssembler::emit_nyi(const char *msg) {
    emit_enter_runtime();

    a.mov(ARG1, imm(msg));
    runtime_call<1>(i_emit_nyi);

    /* Never returns */
}

void BeamModuleAssembler::emit_nyi() {
    emit_nyi("<unspecified>");
}

bool BeamModuleAssembler::emit(unsigned specific_op,
                               const std::vector<ArgVal> &args) {
    comment(opc[specific_op].name);

#ifdef BEAMASM_DUMP_SIZES
    uint64_t before = a.offset();
#endif

#define InstrCnt()
    switch (specific_op) {
#include "beamasm_emit.h"
    default:
        ERTS_ASSERT(0 && "Invalid instruction");
        break;
    }

    if (getOffset() == last_error_offset) {
        /*
         * The previous PC where an exception may occur is equal to the
         * current offset, which is also the offset of the next
         * instruction. If the next instruction happens to be a
         * line instruction, the location for the exception will
         * be that line instruction, which is probably wrong.
         * To avoid that, bump the instruction offset.
         */
        a.nop();
    }

#ifdef BEAMASM_DUMP_SIZES
    {
        std::lock_guard<std::mutex> lock(size_lock);

        sizes[opc[specific_op].name].first++;
        sizes[opc[specific_op].name].second += a.offset() - before;
    }
#endif

    return true;
}

/*
 * Here follows meta instructions.
 */

void BeamGlobalAssembler::emit_i_func_info_shared() {
    /* Pop the ErtsCodeInfo address into ARG1 and mask out the offset added by
     * the call instruction. */
    a.pop(ARG1);
    a.and_(ARG1, ~0x7);

    a.lea(ARG1, x86::qword_ptr(ARG1, offsetof(ErtsCodeInfo, mfa)));

    a.mov(x86::qword_ptr(c_p, offsetof(Process, freason)), EXC_FUNCTION_CLAUSE);
    a.mov(x86::qword_ptr(c_p, offsetof(Process, current)), ARG1);
    a.jmp(labels[error_action_code]);
}

void BeamModuleAssembler::emit_i_func_info(const ArgVal &Label,
                                           const ArgVal &Module,
                                           const ArgVal &Function,
                                           const ArgVal &Arity) {
    ErtsCodeInfo info;

    functions.push_back(Label.getValue());

    info.mfa.module = Module.getValue();
    info.mfa.function = Function.getValue();
    info.mfa.arity = Arity.getValue();
    info.u.gen_bp = NULL;

    comment("%T:%T/%d", info.mfa.module, info.mfa.function, info.mfa.arity);

    /* This is an ErtsCodeInfo structure that has a valid x86 opcode as its `op`
     * field, which *calls* the funcInfo trampoline so we can trace it back to
     * this particular function.
     *
     * We make a relative call to a trampoline in the module header because this
     * needs to fit into a word, and an directy call to `i_func_info_shared`
     * would be too large. */
    if (funcInfo.isValid()) {
        a.call(funcInfo);
    } else {
        a.nop();
    }

    a.align(kAlignCode, sizeof(UWord));
    a.embed(&info.u.gen_bp, sizeof(info.u.gen_bp));
    a.embed(&info.mfa, sizeof(info.mfa));
}

void BeamModuleAssembler::emit_label(const ArgVal &Label) {
    currLabel = labels[Label.getValue()];
    a.bind(currLabel);
}

void BeamModuleAssembler::emit_aligned_label(const ArgVal &Label) {
    a.align(kAlignCode, 8);
    emit_label(Label);
}

void BeamModuleAssembler::emit_on_load() {
    on_load = currLabel;
}

void BeamModuleAssembler::emit_int_code_end() {
    /* This label is used to figure out the end of the last function */
    labels[labels.size() + 1] = a.newLabel();
    a.bind(labels[labels.size()]);

    emit_nyi("int_code_end");
}

void BeamModuleAssembler::emit_line(const ArgVal &) {
    /*
     * There is no need to align the line instruction. In the loaded
     * code, the type of the pointer will be void* and that pointer
     * will only be used in comparisons.
     */
}

void BeamModuleAssembler::emit_func_line(const ArgVal &Loc) {
    emit_line(Loc);
}

void BeamModuleAssembler::emit_empty_func_line() {
}

/*
 * Here follows stubs for instructions that should never be called.
 */

void BeamModuleAssembler::emit_i_debug_breakpoint() {
    emit_nyi("i_debug_breakpoint should never be called");
}

void BeamModuleAssembler::emit_i_generic_breakpoint() {
    emit_nyi("i_generic_breakpoint should never be called");
}

void BeamModuleAssembler::emit_trace_jump(const ArgVal &) {
    emit_nyi("trace_jump should never be called");
}

void *BeamModuleAssembler::codegen(BeamCodeHeader *in_hdr,
                                   BeamCodeHeader **out_hdr) {
    BeamCodeHeader *code_hdr;

    void *module = codegen();
    code_hdr = (BeamCodeHeader *)getCode(codeHeader);

    sys_memcpy(code_hdr, in_hdr, sizeof(BeamCodeHeader));
    code_hdr->on_load_function_ptr = getOnLoad();

    for (unsigned i = 0; i < functions.size(); i++) {
        ErtsCodeInfo *ci = (ErtsCodeInfo *)getCode(functions[i]);
        code_hdr->functions[i] = ci;
    }

    char *module_end = (char *)code.baseAddress() + a.offset();
    code_hdr->functions[functions.size()] = (ErtsCodeInfo *)module_end;

    *out_hdr = code_hdr;

    return module;
}

void *BeamModuleAssembler::codegen() {
    void *module = _codegen();

#ifndef WIN32
    if (functions.size()) {
        char *buff = (char *)erts_alloc(ERTS_ALC_T_TMP, 1024);
        std::vector<AsmRange> ranges;
        std::string name = getAtom(mod);
        ranges.reserve(functions.size() + 2);

        /* Push info about the header */
        ranges.push_back({.start = (BeamInstr *)getBaseAddress(),
                          .stop = getCode(functions[0]),
                          .name = name + "::codeHeader"});

        for (unsigned i = 0; i < functions.size(); i++) {
            BeamInstr *start = getCode(functions[i]);
            ErtsCodeInfo *ci = (ErtsCodeInfo *)start;
            int n = erts_snprintf(buff,
                                  1024,
                                  "%T:%T/%d",
                                  ci->mfa.module,
                                  ci->mfa.function,
                                  ci->mfa.arity);
            std::string name = std::string(buff, n);
            BeamInstr *stop = erts_codeinfo_to_code(ci) +
                              BEAM_ASM_FUNC_PROLOGUE_SIZE / sizeof(UWord);

            /* We use a different symbol for CodeInfo and the Prologue
               in order for the perf disassembly to be better. */
            ranges.push_back({.start = start,
                              .stop = stop,
                              .name = name + "-CodeInfoPrologue"});

            /* The actual code */
            start = stop;
            if (i + 1 < functions.size())
                stop = getCode(functions[i + 1]);
            else {
                stop = getCode(labels.size());
            }
            ranges.push_back({.start = start, .stop = stop, .name = name});
        }

        /* Push info about the footer */
        ranges.push_back(
                {.start = ranges.back().stop,
                 .stop = (BeamInstr *)(code.baseAddress() + code.codeSize()),
                 .name = name + "::codeFooter"});

        update_gdb_jit_info(name, ranges);
        beamasm_update_perf_info(name, ranges);
        erts_free(ERTS_ALC_T_TMP, buff);
    }
#endif
    return module;
}

void BeamModuleAssembler::codegen(char *buff, size_t len) {
    code.flatten();
    code.resolveUnresolvedLinks();
    ERTS_ASSERT(code.codeSize() <= len);
    code.relocateToBase((uint64_t)buff);
    code.copyFlattenedData(buff,
                           code.codeSize(),
                           CodeHolder::kCopyPadSectionBuffer);

#ifdef WIN32
    DWORD old;
    if (!VirtualProtect(buff, len, PAGE_EXECUTE_READWRITE, &old)) {
        erts_exit(-2, "Could not change memory protection");
    }
#endif
}

BeamCodeHeader *BeamModuleAssembler::getCodeHeader() {
    return (BeamCodeHeader *)getCode(codeHeader);
}

BeamInstr *BeamModuleAssembler::getOnLoad() {
    if (on_load.isValid())
        return (BeamInstr *)getCode(on_load);
    else
        return 0;
}

unsigned BeamModuleAssembler::patchCatches() {
    unsigned catch_no = BEAM_CATCHES_NIL;

    for (const auto &c : catches) {
        const auto &patch = c.patch;
        BeamInstr *handler;

        handler = reinterpret_cast<BeamInstr *>(getCode(c.handler));
        catch_no = beam_catches_cons(handler, catch_no, nullptr);

        /* Patch the `mov` instruction with the catch tag */
        char *pp = reinterpret_cast<char *>(getCode(patch.where));
        unsigned *where = (unsigned *)(pp + patch.ptr_offs);
        ASSERT(0x7fffffff == *where);
        Eterm catch_term = make_catch(catch_no);

        /* With the current tag scheme, more than 33 million
         * catches can exist at once. */
        ERTS_ASSERT(catch_term >> 31 == 0);
        *where = (unsigned)catch_term;
    }

    return catch_no;
}

void BeamModuleAssembler::patchImport(unsigned index, BeamInstr I) {
    for (const auto &patch : imports[index].patches) {
        char *pp = reinterpret_cast<char *>(getCode(patch.where));
        Eterm *where = (Eterm *)(pp + patch.ptr_offs);
        ASSERT(LLONG_MAX == *where);
        *where = I + patch.val_offs;
    }
}

void BeamModuleAssembler::patchLambda(unsigned index, BeamInstr I) {
    for (const auto &patch : lambdas[index].patches) {
        char *pp = reinterpret_cast<char *>(getCode(patch.where));
        Eterm *where = (Eterm *)(pp + patch.ptr_offs);
        ASSERT(LLONG_MAX == *where);
        *where = I + patch.val_offs;
    }
}

void BeamModuleAssembler::patchLiteral(unsigned index, Eterm lit) {
    for (const auto &patch : literals[index].patches) {
        char *pp = reinterpret_cast<char *>(getCode(patch.where));
        Eterm *where = (Eterm *)(pp + patch.ptr_offs);
        ASSERT(LLONG_MAX == *where);
        *where = lit + patch.val_offs;
    }
}

void BeamModuleAssembler::patchStrings(byte *strtab) {
    for (const auto &patch : strings) {
        char *pp = reinterpret_cast<char *>(getCode(patch.where));
        byte **where = (byte **)(pp + 2);
        ASSERT(LLONG_MAX == (Eterm)*where);
        *where = strtab + patch.val_offs;
    }
}
