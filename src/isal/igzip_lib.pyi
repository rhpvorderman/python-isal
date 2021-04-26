# Copyright (c) 2020 Leiden University Medical Center
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

ISAL_BEST_SPEED: int
ISAL_BEST_COMPRESSION: int
ISAL_DEFAULT_COMPRESSION: int
DEF_BUF_SIZE: int
MAX_HIST_BITS: int
ISAL_NO_FLUSH: int
ISAL_SYNC_FLUSH: int
ISAL_FULL_FLUSH: int
COMP_DEFLATE: int
COMP_GZIP: int
COMP_GZIP_NO_HDR: int
COMP_ZLIB: int
COMP_ZLIB_NO_HDR: int
DECOMP_DEFLATE: int
DECOMP_ZLIB: int
DECOMP_GZIP: int
DECOMP_GZIP_NO_HDR: int
DECOMP_ZLIB_NO_HDR: int
DECOMP_ZLIB_NO_HDR_VER: int
DECOMP_GZIP_NO_HDR_VER: int
MEM_LEVEL_DEFAULT: int
MEM_LEVEL_MIN: int
MEM_LEVEL_SMALL: int
MEM_LEVEL_MEDIUM: int
MEM_LEVEL_LARGE: int
MEM_LEVEL_EXTRA_LARGE: int
IsalError: OSError

def compress(data, level: int = ISAL_DEFAULT_COMPRESSION,
             flag: int = COMP_DEFLATE,
             mem_level: int = MEM_LEVEL_DEFAULT,
             hist_bits: int = MAX_HIST_BITS) -> bytes: ...
def decompress(data, flag: int = DECOMP_DEFLATE,
               hist_bits: int = MAX_HIST_BITS,
               bufsize: int = DEF_BUF_SIZE) -> bytes: ...

class IgzipDecompressor:
    unused_data: bytes
    needs_input: bool
    eof: bool

    def decompress(self, data, max_length = -1) -> bytes: ...
