/* strata-rtl in the browser: three calls Verilator's run time makes to pin
 * its threads to CPUs, which Emscripten's C library does not have. The
 * model runs on one thread (the worker's), so there is nothing to pin: they
 * report failure. Kept in C, without headers, so that the declarations in
 * Emscripten's (which differ between its versions) cannot disagree. */
int pthread_getaffinity_np(void *thread, unsigned long size, void *set) {
  (void)thread; (void)size; (void)set;
  return 1; /* an error number: no affinity */
}
int pthread_setaffinity_np(void *thread, unsigned long size, const void *set) {
  (void)thread; (void)size; (void)set;
  return 1;
}
int sched_getcpu(void) { return 0; }
