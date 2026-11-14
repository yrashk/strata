/* fsl: the file system's trees, as much of them as the host tools need:
 * making a file with its tags and attributes, the boot manifest, reading,
 * checking and listing. The file system itself is os/servers/fs.s.
 *
 * Namespace "fs" holds five trees.
 *   obj   object id (u64 big-endian) -> the record (a blob):
 *           0 u8 kind (1 file), 1 u8 flags (1 boot), 2 u16 tags, 4 u16
 *           attributes, 6 u16 name length, 8 u64 size, 16 u64 created, 24
 *           u64 modified (commit numbers), 32 the name, then a u32 tag id
 *           per tag, then per attribute: u32 id, u8 type (0 integer, 1
 *           string), u8 length, the value (an integer: 8 bytes)
 *   data  object id -> the contents (a blob; none when the file is empty)
 *   name  name -> u64 object id
 *   attr  u32 attribute id (big-endian), value, object id (big-endian) -> nothing
 *           1 tag (value: u32 tag id, big-endian), 2 size and 3 modified
 *           (u64 big-endian), 4 boot (no value); from 16 on, attributes by
 *           name: integers as u64 big-endian, strings with a zero byte after
 *   dict  "!" -> u64 next object id, u64 objects, u32 next tag id, u32 next
 *           attribute id; "t" tag name -> u32 id, u32 0, u64 objects carrying
 *           it; "T" id (big-endian) -> name; "a" attribute name -> u32 id,
 *           u32 type; "A" id (big-endian) -> name
 * The boot manifest (the meta page points at it; the kernel loads the first
 * servers from it): a page of kind 3 with "STBOOTMF" at 32, a u32 count at
 * 40 and from 64 entries of {name[16], u64 first page, u64 bytes}: the
 * objects with the boot flag, each in one extent. */
#ifndef FSL_H
#define FSL_H
#include "stdb.h"

enum { FS_A_TAG = 1, FS_A_SIZE = 2, FS_A_MOD = 3, FS_A_BOOT = 4, FS_A_USER = 16 };
enum { FS_BOOT = 1 };
#define FS_NAMEMAX 255
#define FS_RECMAX 4000

typedef struct {
  Store *st;
  uint32_t ns;
  StTree *obj, *data, *name, *attr, *dict;
  uint64_t nextoid, nobj;
  uint32_t nexttag, nextattr;
  int bootdirty;
  char msg[160];
} Fs;

typedef struct {
  uint64_t oid, size, created, modified;
  int kind, flags, nl, ntags, nattr;
  char name[FS_NAMEMAX + 1];
  uint32_t tags[256];
  struct { uint32_t id; int type, len; uint8_t val[256]; } attr[32];
} FsRec;

void fs_mkfs(Store *st, Fs *fs);
int fs_open(Store *st, Fs *fs); /* -1: the store has no file system */
/* A new file: its id, or -1 (fs->msg says why). tags: ntags strings. */
int64_t fs_add(Fs *fs, const char *name, const uint8_t *data, uint64_t len,
               const char **tags, int ntags, int boot);
int fs_setattr(Fs *fs, uint64_t oid, const char *aname, int type, const uint8_t *val, int len);
int64_t fs_lookup(Fs *fs, const char *name);
int fs_rec(Fs *fs, uint64_t oid, FsRec *r);
int fs_tagname(Fs *fs, uint32_t id, char *out);  /* its length, or -1 */
int fs_attrname(Fs *fs, uint32_t id, char *out);
int64_t fs_read(Fs *fs, uint64_t oid, uint64_t off, uint8_t *b, uint64_t len);
/* The names in order: the one after `name` (first: an empty one) -> name; 0 at the end. */
int fs_nextname(Fs *fs, char *name, uint64_t *oid);
int fs_commit(Fs *fs); /* -1: a boot object is not in one piece (fs->msg) */
int fs_check(Fs *fs, FILE *out);
void fs_dump(Fs *fs, FILE *out);
#endif
