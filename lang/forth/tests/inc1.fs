\ inc1.fs: included by ostest.fs; includes another file in the middle of a line
: from-inc1 ( -- ) ." inc1 " ;
include inc2.fs  from-inc2
from-inc1
