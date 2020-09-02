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

from pathlib import Path
import itertools
import zlib

from isal import isal_zlib

import pytest

DATA_DIR = Path(__file__).parent / "data"
DATA_FILE =  DATA_DIR / "512kb.txt"
DATA_512KB = DATA_FILE.read_bytes()
# Create data  chunks from 8 KB until 64 KB.
DATA_CHUNKS = [DATA_512KB[0:2**i] for i in range(3,17)]
# 100 seeds generated with random.randint(0, 2**32-1)
SEEDS_FILE = DATA_DIR / "seeds.txt"
# Create seeds 0, 1 and 20 seeds from the seeds file.
SEEDS = [0, 1] + [int(seed) for seed in SEEDS_FILE.read_text().splitlines()[:20]]


@pytest.mark.parametrize(["data", "value"], itertools.product(DATA_CHUNKS, SEEDS))
def test_crc32(data, value):
    assert zlib.crc32(data, value) == isal_zlib.crc32(data, value)


@pytest.mark.parametrize(["data", "value"], itertools.product(DATA_CHUNKS, SEEDS))
def test_adler32(data, value):
    assert zlib.adler32(data, value) == isal_zlib.adler32(data, value)

@pytest.mark.parametrize(["data", "level"], itertools.product(DATA_CHUNKS, range(4)))
def test_compress(data, level):
    assert zlib.decompress(isal_zlib.compress(data, level=level)) == data