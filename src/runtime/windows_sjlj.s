/*
 * Eiwa runtime: direct register save/restore setjmp/longjmp for Windows x86_64.
 *
 * Windows CRT's longjmp forces SEH stack unwinding via RtlUnwindEx, which
 * crashes in MCJIT because JIT-compiled stack frames have no system function
 * table (.pdata) entries registered in the kernel.
 *
 * This implementation directly saves and restores the Windows x64 ABI
 * callee-saved registers without triggering SEH unwinding.
 */

#if defined(__x86_64__) || defined(_M_X64)

.text
.global eiwa_setjmp
.def eiwa_setjmp; .scl 2; .type 32; .endef
eiwa_setjmp:
    movq %rbx, 0(%rcx)
    leaq 8(%rsp), %rax
    movq %rax, 8(%rcx)
    movq %rbp, 16(%rcx)
    movq %rsi, 24(%rcx)
    movq %rdi, 32(%rcx)
    movq %r12, 40(%rcx)
    movq %r13, 48(%rcx)
    movq %r14, 56(%rcx)
    movq %r15, 64(%rcx)
    movq (%rsp), %rax
    movq %rax, 72(%rcx)
    movdqu %xmm6, 80(%rcx)
    movdqu %xmm7, 96(%rcx)
    movdqu %xmm8, 112(%rcx)
    movdqu %xmm9, 128(%rcx)
    movdqu %xmm10, 144(%rcx)
    movdqu %xmm11, 160(%rcx)
    movdqu %xmm12, 176(%rcx)
    movdqu %xmm13, 192(%rcx)
    movdqu %xmm14, 208(%rcx)
    movdqu %xmm15, 224(%rcx)
    xorl %eax, %eax
    ret

.global eiwa_longjmp
.def eiwa_longjmp; .scl 2; .type 32; .endef
eiwa_longjmp:
    movl %edx, %eax
    testl %eax, %eax
    jnz 1f
    movl $1, %eax
1:
    movq 0(%rcx), %rbx
    movq 8(%rcx), %rsp
    movq 16(%rcx), %rbp
    movq 24(%rcx), %rsi
    movq 32(%rcx), %rdi
    movq 40(%rcx), %r12
    movq 48(%rcx), %r13
    movq 56(%rcx), %r14
    movq 64(%rcx), %r15
    movdqu 80(%rcx), %xmm6
    movdqu 96(%rcx), %xmm7
    movdqu 112(%rcx), %xmm8
    movdqu 128(%rcx), %xmm9
    movdqu 144(%rcx), %xmm10
    movdqu 160(%rcx), %xmm11
    movdqu 176(%rcx), %xmm12
    movdqu 192(%rcx), %xmm13
    movdqu 208(%rcx), %xmm14
    movdqu 224(%rcx), %xmm15
    movq 72(%rcx), %rdx
    jmp *%rdx

#endif
