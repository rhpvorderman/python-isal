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

import itertools
import os
import pickle
from typing import NamedTuple

from isal import igzip_lib
from isal.igzip_lib import (
    COMP_DEFLATE, COMP_GZIP, COMP_GZIP_NO_HDR, COMP_ZLIB, COMP_ZLIB_NO_HDR,
    DECOMP_DEFLATE, DECOMP_GZIP, DECOMP_GZIP_NO_HDR, DECOMP_GZIP_NO_HDR_VER,
    DECOMP_ZLIB, DECOMP_ZLIB_NO_HDR, DECOMP_ZLIB_NO_HDR_VER, MEM_LEVEL_DEFAULT,
    MEM_LEVEL_EXTRA_LARGE, MEM_LEVEL_LARGE, MEM_LEVEL_MEDIUM, MEM_LEVEL_MIN,
    MEM_LEVEL_SMALL)
from isal.igzip_lib import IgzipDecompressor

import pytest

from .test_compat import DATA as RAW_DATA


class Flag(NamedTuple):
    comp: int
    decomp: int


DATA = RAW_DATA[:128 * 1024]

COMPRESS_LEVELS = list(range(4))
HIST_BITS = list(range(16))
FLAGS = [
    Flag(COMP_DEFLATE, DECOMP_DEFLATE),
    Flag(COMP_ZLIB, DECOMP_ZLIB),
    Flag(COMP_GZIP, DECOMP_GZIP),
    Flag(COMP_ZLIB_NO_HDR, DECOMP_ZLIB_NO_HDR),
    Flag(COMP_GZIP_NO_HDR, DECOMP_GZIP_NO_HDR),
    Flag(COMP_ZLIB_NO_HDR, DECOMP_ZLIB_NO_HDR_VER),
    Flag(COMP_GZIP_NO_HDR, DECOMP_GZIP_NO_HDR_VER),
]
MEM_LEVELS = [MEM_LEVEL_DEFAULT, MEM_LEVEL_MIN, MEM_LEVEL_SMALL,
              MEM_LEVEL_MEDIUM, MEM_LEVEL_LARGE, MEM_LEVEL_EXTRA_LARGE]


@pytest.mark.parametrize(["level", "flag", "mem_level", "hist_bits"],
                         itertools.product(
                             COMPRESS_LEVELS, FLAGS, MEM_LEVELS, HIST_BITS))
def test_compress_decompress(level, flag: Flag, mem_level, hist_bits):
    comp = igzip_lib.compress(DATA, level, flag.comp, mem_level, hist_bits)
    decomp = igzip_lib.decompress(comp, flag.decomp, hist_bits)
    assert decomp == DATA


class TestIgzipDecompressor():
    # Tests adopted from CPython's test_bz2.py
    TEXT = DATA
    DATA = igzip_lib.compress(DATA)
    BAD_DATA = b"Not a valid deflate block"

    def test_decompress(self):
        decomp = IgzipDecompressor()
        decompressed = decomp.decompress(self.DATA)
        assert decompressed == self.TEXT

    def testDecompressChunks10(self):
        igzd = IgzipDecompressor()
        text = b''
        n = 0
        while True:
            str = self.DATA[n*10:(n+1)*10]
            if not str:
                break
            text += igzd.decompress(str)
            n += 1
        assert text == self.TEXT

    def testDecompressUnusedData(self):
        igzd = IgzipDecompressor()
        unused_data = b"this is unused data"
        text = igzd.decompress(self.DATA+unused_data)
        assert text == self.TEXT
        assert igzd.unused_data == unused_data

    def testEOFError(self):
        igzd = IgzipDecompressor()
        igzd.decompress(self.DATA)
        with pytest.raises(EOFError):
            igzd.decompress(b"anything")
        with pytest.raises(EOFError):
            igzd.decompress(b"")

    def testDecompress4G(self):
        # "Test igzdecompressor.decompress() with >4GiB input"
        size = 4 * 1024 ** 3 + 100  # 4 GiB + 100
        blocksize = 10 * 1024 * 1024
        block = os.urandom(blocksize)
        try:
            data = block * (size // blocksize + 1)
            compressed = igzip_lib.compress(data)
            igzd = IgzipDecompressor()
            decompressed = igzd.decompress(compressed)
            assert decompressed == data
        finally:
            data = None
            compressed = None
            decompressed = None

    def testPickle(self):
        for proto in range(pickle.HIGHEST_PROTOCOL + 1):
            with pytest.raises(TypeError):
                pickle.dumps(IgzipDecompressor(), proto)

    def testDecompressorChunksMaxsize(self):
        igzd = IgzipDecompressor()
        max_length = 100
        out = []

        # Feed some input
        len_ = len(self.DATA) - 64
        out.append(igzd.decompress(self.DATA[:len_],
                                   max_length=max_length))
        assert not igzd.needs_input
        assert len(out[-1]) == max_length

        # Retrieve more data without providing more input
        out.append(igzd.decompress(b'', max_length=max_length))
        assert not igzd.needs_input
        assert len(out[-1]) == max_length

        # Retrieve more data while providing more input
        out.append(igzd.decompress(self.DATA[len_:],
                                   max_length=max_length))
        assert len(out[-1]) == max_length

        # Retrieve remaining uncompressed data
        while not igzd.eof:
            out.append(igzd.decompress(b'', max_length=max_length))
            assert len(out[-1]) <= max_length

        out = b"".join(out)
        assert out == self.TEXT
        assert igzd.unused_data == b""

    def test_decompressor_inputbuf_1(self):
        # Test reusing input buffer after moving existing
        # contents to beginning
        igzd = IgzipDecompressor()
        out = []

        # Create input buffer and fill it
        assert igzd.decompress(self.DATA[:100], max_length=0) == b''

        # Retrieve some results, freeing capacity at beginning
        # of input buffer
        out.append(igzd.decompress(b'', 2))

        # Add more data that fits into input buffer after
        # moving existing data to beginning
        out.append(igzd.decompress(self.DATA[100:105], 15))

        # Decompress rest of data
        out.append(igzd.decompress(self.DATA[105:]))
        assert b''.join(out) == self.TEXT

    def test_decompressor_inputbuf_2(self):
        # Test reusing input buffer by appending data at the
        # end right away
        igzd = IgzipDecompressor()
        out = []

        # Create input buffer and empty it
        assert igzd.decompress(self.DATA[:200], max_length=0) == b''
        out.append(igzd.decompress(b''))

        # Fill buffer with new data
        out.append(igzd.decompress(self.DATA[200:280], 2))

        # Append some more data, not enough to require resize
        out.append(igzd.decompress(self.DATA[280:300], 2))

        # Decompress rest of data
        out.append(igzd.decompress(self.DATA[300:]))
        assert b''.join(out) == self.TEXT

    def test_decompressor_inputbuf_3(self):
        # Test reusing input buffer after extending it

        igzd = IgzipDecompressor()
        out = []

        # Create almost full input buffer
        out.append(igzd.decompress(self.DATA[:200], 5))

        # Add even more data to it, requiring resize
        out.append(igzd.decompress(self.DATA[200:300], 5))

        # Decompress rest of data
        out.append(igzd.decompress(self.DATA[300:]))
        assert b''.join(out) == self.TEXT

    def test_failure(self):
        igzd = IgzipDecompressor()
        with pytest.raises(Exception):
            igzd.decompress(self.BAD_DATA * 30)
        # Make sure there are no internal consistencies
        with pytest.raises(Exception):
            igzd.decompress(self.BAD_DATA * 30)
