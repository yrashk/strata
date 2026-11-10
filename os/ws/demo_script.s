; =============================================================================
; demo_script.s: the demo terminals' scripted sessions (fake output)
; =============================================================================
;
; Line kinds (wsdemo.s tc_tick): "$ cmd" the prompt, then cmd typed a
; character a frame; "~" half a second's pause; "%" the prompt, and stop;
; anything else one line of output (with the 2.6 escape sequences).

        .data                           ; D-LS
prompt_a: .ascii "\x1b[96mstrata\x1b[90m@\x1b[0m7\x1b[96m>\x1b[0m " ; the prompts (core 7, core 8)
prompt_a_e:                             ; ...
prompt_b: .ascii "\x1b[96mstrata\x1b[90m@\x1b[0m8\x1b[96m>\x1b[0m " ; ...
prompt_b_e:                             ; ...
script_a:                               ; terminal A: a tour
        .ascii "\x1b[1;96mStrataOS 0.1\x1b[0m \x1b[90m\x81\x1b[0m 12 cores \x1b[90m\x81\x1b[0m 64 MiB \x1b[90m\x81\x1b[0m memory is explicit I/O\n"
        .ascii "\x1b[90mtype help; Alt+P or Alt+Space to launch\x1b[0m\n"
        .ascii "~\n"
        .ascii "$ uptime\n"
        .ascii " 21:47:05  up 0:12:43,  14 processes,  1.2k switches/s\n"
        .ascii "$ ls\n"
        .ascii "\x1b[92mas\x1b[0m       \x1b[92mcat\x1b[0m      \x1b[92mcores\x1b[0m    \x1b[92mdevs\x1b[0m     \x1b[92mdf\x1b[0m       \x1b[92mforth\x1b[0m    \x1b[92mgrep\x1b[0m\n"
        .ascii "\x1b[92mls\x1b[0m       \x1b[92mmandel\x1b[0m   \x1b[92mps\x1b[0m       \x1b[92mrm\x1b[0m       \x1b[92mseq\x1b[0m      \x1b[92msh\x1b[0m       \x1b[92mspin\x1b[0m\n"
        .ascii "\x1b[92mterm\x1b[0m     \x1b[92munits\x1b[0m    \x1b[92muptime\x1b[0m   \x1b[92mwc\x1b[0m       \x1b[92mwclock\x1b[0m   \x1b[92mwmandel\x1b[0m  \x1b[92mws\x1b[0m\n"
        .ascii "mandel.s motd     rc       units.s\n"
        .ascii "$ run -n 4 mandel\n"
        .ascii "mandel: 4 threads on cores 7..10, one band each (cgive)\n"
        .ascii "\x1b[92m  ok\x1b[0m  80 x 40 points, 1.92M iterations, 38.4 ms\n"
        .ascii "$ cat motd\n"
        .ascii "Welcome to StrataOS 0.1. Loads and stores reach only the\n"
        .ascii "Local Stores; everything else is a transfer you can see:\n"
        .ascii "\x1b[93mtget\x1b[0m, \x1b[93mtput\x1b[0m, \x1b[93mtamo\x1b[0m. No caches, no interrupts, no secrets.\n"
        .ascii "$ spin &\n"
        .ascii "[1] 14\n"
        .ascii "$ wc -l < motd\n"
        .ascii "3\n"
        .ascii "%\n"
script_b:                               ; terminal B: where the time goes
        .ascii "~\n"
        .ascii "$ ps\n"
        .ascii "\x1b[1;96m  PID NAME     CORE  STATE       SWITCHES   KIB MOVED\x1b[0m\n"
        .ascii "    1 proc        1  \x1b[90mserver\x1b[0m             0         0.0\n"
        .ascii "    3 fs          3  \x1b[90mserver\x1b[0m             0         0.0\n"
        .ascii "    6 ws          6  \x1b[90mserver\x1b[0m             0         0.0\n"
        .ascii "    7 sh          7  \x1b[93mwait\x1b[0m             201      1934.0\n"
        .ascii "    8 term        7  \x1b[92mrun\x1b[0m              104      1482.4\n"
        .ascii "   11 wmandel     9  \x1b[92mrun\x1b[0m              117      2207.6\n"
        .ascii "   12 wclock     10  \x1b[93mwait\x1b[0m              47       304.0\n"
        .ascii "   14 spin        9  \x1b[92mrun\x1b[0m              887      3550.0\n"
        .ascii "$ cores\n"
        .ascii "\x1b[1;96mCORE  RUNNING   QUEUE   SW/S   KIB/S\x1b[0m\n"
        .ascii "   0  \x1b[90mkernel\x1b[0m        -      -       -\n"
        .ascii "   7  term          2     96   1366.1\n"
        .ascii "   8  sh            2     71    681.6\n"
        .ascii "   9  wmandel       2    104   1955.2\n"
        .ascii "  10  wclock        1     12     76.8\n"
        .ascii "  11  \x1b[90midle\x1b[0m          0      3      9.6\n"
        .ascii "\x1b[90ma context switch moves the D-LS in use: the cost is explicit\x1b[0m\n"
        .ascii "%\n"
        .align 8                        ; ...
        .text                           ; code
