/* Strata prototype: the platform description and device ROM contents.
 *
 * Shared by the emulator and the RTL harness so both machines describe
 * themselves identically. Header-only.
 *
 * Device space (SP_DEV) map:
 *   0x0000  console         port 0x0000: output stream, port 0x0008: input
 *                           stream (blocks until a byte arrives; 0x04 at
 *                           end of input), port 0x0010: break stream (a
 *                           read completes when Ctrl-C is pressed), port
 *                           0x0018: writing completes every pending break
 *                           read and every console input read waiting for
 *                           its first byte, with 0
 *   0x1000  platform table  read-only, random access, PLAT_LEN bytes
 *   0x2000  block device 0  0x2000 identify ROM (64 B), 0x2100 submission
 *                           stream (32-byte commands), 0x2200 completion
 *                           stream (16-byte entries)
 *   0x3000  timer           0x3000 NOW (ticks since power-on, 1 tick = 1 us),
 *                           0x3008 FREQ (1000000), 0x3010 DEADLINE (read/
 *                           write, absolute ticks), 0x3018 WAIT (a read
 *                           completes once NOW >= DEADLINE, returning NOW)
 *   0x4000  framebuffer     0x4000 PRESENT (write: show the framebuffer
 *           controller      region), 0x4008 VSYNC (a read completes at the
 *                           next 60 Hz refresh, every 16667 ticks, returning
 *                           the frame number)
 *   0x4100  pointer         0x4100 EVENT (a read completes when an event is
 *                           queued and returns it: u16 x, u16 y in
 *                           framebuffer pixels, u8 buttons (bit 0 left, 1
 *                           right, 2 middle), s8 wheel y (> 0: away from the
 *                           user), s8 wheel x (> 0: right), u8 kind (1 move,
 *                           2 button, 3 wheel, 4 enter, 5 leave); a write
 *                           completes every waiting EVENT read with 0),
 *                           0x4108 STATE (read: u16 x, u16 y, u8 buttons, u8
 *                           events queued, u8 0, u8 bit 0 = the pointer is
 *                           over the display)
 *   0x4200  network         0x4200 TX (write: one transfer = one IPv4
 *           interface       packet, NET_MTU bytes at most), 0x4208 RX (a read
 *                           completes when a packet is queued: byte i is the
 *                           packet's byte i, zero past its end; the packet
 *                           leaves the queue), 0x4210 STATUS (read: u16 length
 *                           of the next queued packet, u8 packets queued, u8
 *                           bit 0 link up, u32 packets dropped), 0x4218
 *                           CANCEL (write: completes every waiting RX read
 *                           with zeros, consuming nothing)
 *
 * Device registers are 8 bytes, little endian, at 8-byte-aligned ports; a
 * transfer moves one byte per beat to consecutive ports. A register is
 * latched when its byte 0 is read and a write takes effect when its byte 7
 * is written. A read that cannot complete yet (console input, break, WAIT,
 * VSYNC, the pointer's EVENT, the network's RX) stays in flight until it can, without holding up anything else.
 *
 * The framebuffer is ordinary system memory (T3): a fixed window of FB_SIZE
 * bytes at FB_BASE, of which the display scans out the first height x stride
 * bytes. The geometry is a property of the machine (default FB_DEF_WIDTH x
 * FB_DEF_HEIGHT, `-r WxH` on both simulators), reported by the platform
 * table: stride = width x 4, XRGB8888 (bytes in memory: B, G, R, unused).
 *
 * Platform table ("STPD"), little endian:
 *   header 32 B: magic "STPD", u16 version, u16 entry size, u16 entries,
 *                u16 cores, u32 total length, u32 checksum, u16 entries
 *                of each core's capability save table (CTAB; 0 means 64),
 *                u16 entries of each core's overlay map (NXMAP; 0 means
 *                16), 8 B reserved
 *   entry  32 B: u16 type, u16 index, u16 space, u16 node (cgive target,
 *                0xffff if none), u64 info, u64 base, u64 size
 *   checksum = sum of all bytes with the checksum field zero, mod 2^32 */
#ifndef STRATA_PLATFORM_H
#define STRATA_PLATFORM_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../asm/isa.h"

#define DEV_SPACE_LEN 0x5000u
#define DEV_CONSOLE 0x0000u
#define CON_IN 0x0008u
#define CON_BREAK 0x0010u   /* read: completes when the user presses Ctrl-C (returns 3) */
#define CON_RELEASE 0x0018u /* write: completes every pending break and input read (all cores) with 0 */
#define DEV_PLAT 0x1000u
#define DEV_BLK0 0x2000u
#define BLK_IDENT 0x000u
#define BLK_SQ 0x100u
#define BLK_CQ 0x200u
#define BLK_WINDOW 0x300u
#define DEV_TIMER 0x3000u
#define TMR_NOW 0x00u
#define TMR_FREQ 0x08u
#define TMR_DEADLINE 0x10u
#define TMR_WAIT 0x18u
#define TMR_WINDOW 0x20u
#define TMR_HZ 1000000u     /* ticks per second */
#define DEV_FBCTL 0x4000u
#define FBC_PRESENT 0x00u
#define FBC_VSYNC 0x08u
#define FB_FRAME_TICKS 16667u /* one display refresh (60 Hz) in timer ticks */
#define DEV_POINTER 0x4100u
#define PTR_EVENT 0x00u     /* read: the next event (waits for one); write: completes waiting reads with 0 */
#define PTR_STATE 0x08u     /* read: position, buttons, events queued, presence */
#define PTR_WINDOW 0x10u
#define PTR_QLEN 16         /* events the device queues */
#define PTR_CAPS 0x0307u    /* platform info: buttons left | right | middle, wheel y | wheel x << 8 */
enum { PTR_MOVE = 1, PTR_BUTTON, PTR_WHEEL, PTR_ENTER, PTR_LEAVE }; /* event kinds */
#define DEV_NET 0x4200u     /* the network interface: raw IPv4 packets, no link-layer framing */
#define NET_TX 0x00u        /* write: a transfer that starts here is one packet */
#define NET_RX 0x08u        /* read: waits for a packet; the transfer gets its first bytes */
#define NET_STATUS 0x10u    /* read: next length | queued << 16 | link << 24 | drops << 32 */
#define NET_CANCEL 0x18u    /* write: completes every waiting RX read with zeros */
#define NET_WINDOW 0x20u
#define NET_MTU 1500u       /* largest packet; platform info */
#define NET_QLEN 16         /* received packets the device queues */

#define FB_BASE 0x3000000u
#define FB_SIZE 0x1000000u
#define FB_DEF_WIDTH 1280u
#define FB_DEF_HEIGHT 800u
#define FB_MIN_WIDTH 320u     /* -r limits; the width must be a multiple of 8 */
#define FB_MIN_HEIGHT 200u
#define FB_MAX_WIDTH 2560u
#define FB_MAX_HEIGHT 1600u
#define FB_FORMAT 1u          /* XRGB8888 */

#define PT_MEMORY 1
#define PT_CONSOLE 2
#define PT_PLATFORM 3
#define PT_BLOCK 4
#define PT_FB 5
#define PT_TIMER 6
#define PT_POINTER 7
#define PT_NET 8

#define PLAT_ENTRIES 9
#define PLAT_LEN (32 + 32 * PLAT_ENTRIES)
#define BLK_IDENT_LEN 64

#define BLK_BLOCK 512u
#define BLK_MAXCMD 256u /* blocks per command */
#define BLK_QDEPTH 4u

/* the capability save table: entries per core (csave / crestore with an
 * immediate reach slots 0..63, csavex / crestorex any slot below CTAB) */
#define CTAB_DEF 256u /* the default, and the RTL's */
#define CTAB_MIN 64u
#define CTAB_MAX 256u

/* the overlay map: entries per core (xmap / xunmap indexes 0..NXMAP-1) */
#define NXMAP_DEF 16u /* the default (the RTL's NXMAP parameter, 4..16) */
#define NXMAP_MIN 4u
#define NXMAP_MAX 16u

/* block commands and statuses */
#define BLK_OP_READ 1
#define BLK_OP_WRITE 2
#define BLK_OP_FLUSH 3
#define BLK_OK 0
#define BLK_E_OP 1
#define BLK_E_LBA 2
#define BLK_E_RANGE 3
#define BLK_E_PERM 4

static inline void plat_put(uint8_t *p, uint64_t v, int n) {
  for (int i = 0; i < n; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static inline void plat_entry(uint8_t *e, int type, int index, int space, int node, uint64_t base,
                              uint64_t size, uint64_t info) {
  plat_put(e + 0, (uint64_t)type, 2);
  plat_put(e + 2, (uint64_t)index, 2);
  plat_put(e + 4, (uint64_t)space, 2);
  plat_put(e + 6, (uint64_t)node, 2);
  plat_put(e + 8, info, 8);
  plat_put(e + 16, base, 8);
  plat_put(e + 24, size, 8);
}

/* Fills buf[PLAT_LEN] for a framebuffer of fb_w x fb_h pixels, a save table of ctab entries and
 * an overlay map of nxmap entries. */
static inline void plat_build_fb(uint8_t *buf, int ncores, uint64_t disk_blocks, unsigned fb_w, unsigned fb_h,
                                 unsigned ctab, unsigned nxmap) {
  memset(buf, 0, PLAT_LEN);
  memcpy(buf, "STPD", 4);
  plat_put(buf + 4, 1, 2);
  plat_put(buf + 6, 32, 2);
  plat_put(buf + 8, PLAT_ENTRIES, 2);
  plat_put(buf + 10, (uint64_t)ncores, 2);
  plat_put(buf + 12, PLAT_LEN, 4);
  plat_put(buf + 20, ctab, 2);
  plat_put(buf + 22, nxmap, 2);
  uint8_t *e = buf + 32;
  plat_entry(e + 0 * 32, PT_MEMORY, 0, 3, 0xffff, 0, T3_BYTES, 0);
  plat_entry(e + 1 * 32, PT_MEMORY, 1, 2, 0xffff, 0, T2_BYTES, 0);
  plat_entry(e + 2 * 32, PT_CONSOLE, 0, 4, 0xffff, DEV_CONSOLE, 0x100, 3); /* info: 1 output | 2 input */
  plat_entry(e + 3 * 32, PT_PLATFORM, 0, 4, 0xffff, DEV_PLAT, PLAT_LEN, 1);
  plat_entry(e + 4 * 32, PT_BLOCK, 0, 4, ncores, DEV_BLK0, BLK_WINDOW, disk_blocks);
  plat_entry(e + 5 * 32, PT_FB, 0, 3, 0xffff, FB_BASE, FB_SIZE,
             (uint64_t)fb_w | (uint64_t)fb_h << 16 | (uint64_t)(fb_w * 4) << 32 | (uint64_t)FB_FORMAT << 48);
  plat_entry(e + 6 * 32, PT_TIMER, 0, 4, 0xffff, DEV_TIMER, TMR_WINDOW, TMR_HZ);
  plat_entry(e + 7 * 32, PT_POINTER, 0, 4, 0xffff, DEV_POINTER, PTR_WINDOW, PTR_CAPS);
  plat_entry(e + 8 * 32, PT_NET, 0, 4, 0xffff, DEV_NET, NET_WINDOW, NET_MTU); /* info: the MTU */
  uint32_t sum = 0;
  for (int i = 0; i < PLAT_LEN; i++) sum += buf[i];
  plat_put(buf + 16, sum, 4);
}

/* Fills buf[PLAT_LEN] with the default framebuffer geometry and save table. */
static inline void plat_build(uint8_t *buf, int ncores, uint64_t disk_blocks, unsigned nxmap) {
  plat_build_fb(buf, ncores, disk_blocks, FB_DEF_WIDTH, FB_DEF_HEIGHT, CTAB_DEF, nxmap);
}

/* Parses -r WxH; false if malformed or out of range. */
static inline bool fb_parse_geometry(const char *s, unsigned *w, unsigned *h) {
  char *e;
  unsigned long a = strtoul(s, &e, 10);
  if (*e != 'x' && *e != 'X') return false;
  unsigned long b = strtoul(e + 1, &e, 10);
  if (*e || a % 8 || a < FB_MIN_WIDTH || a > FB_MAX_WIDTH || b < FB_MIN_HEIGHT || b > FB_MAX_HEIGHT) return false;
  *w = (unsigned)a;
  *h = (unsigned)b;
  return true;
}

/* Fills buf[BLK_IDENT_LEN]: "STBD", u16 version, u16 log2 block size,
 * u64 capacity in blocks, u32 max blocks per command, u32 queue depth. */
static inline void blk_ident(uint8_t *buf, uint64_t blocks) {
  memset(buf, 0, BLK_IDENT_LEN);
  memcpy(buf, "STBD", 4);
  plat_put(buf + 4, 1, 2);
  plat_put(buf + 6, 9, 2);
  plat_put(buf + 8, blocks, 8);
  plat_put(buf + 16, BLK_MAXCMD, 4);
  plat_put(buf + 20, BLK_QDEPTH, 4);
}

#endif
