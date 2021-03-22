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

"""Similar to the stdlib gzip module. But using the Intel Storage Accelaration
Library to speed up its methods."""

import argparse
import gzip
import io
import os
import struct
import sys
import datetime
import time
import typing
from typing import Optional

from . import isal_zlib

__all__ = ["IGzipFile", "open", "compress", "decompress", "BadGzipFile"]

_COMPRESS_LEVEL_FAST = isal_zlib.ISAL_BEST_SPEED
_COMPRESS_LEVEL_TRADEOFF = isal_zlib.ISAL_DEFAULT_COMPRESSION
_COMPRESS_LEVEL_BEST = isal_zlib.ISAL_BEST_COMPRESSION

try:
    BadGzipFile = gzip.BadGzipFile  # type: ignore
except AttributeError:  # Versions lower than 3.8 do not have BadGzipFile
    BadGzipFile = OSError


FTEXT, FHCRC, FHEXTRA, FNAME, FCOMMENT = 1, 2, 4, 8, 16


class GzipHeader(typing.NamedTuple):
    _magic: bytes
    method: int
    flag: int
    mtime: int
    xfl: int
    os: int
    _xlen: Optional[int]
    xtra: Optional[bytes]
    fname: Optional[bytes]
    fcomment: Optional[bytes]
    fhcrc: Optional[int]

    def __init__(self,
                 data_is_ascii: bool = False,
                 mtime: int = 0,
                 xfl = 0,
                 os: int = 255,  # Unknown OS
                 xtra: bytes = None,
                 fname: Optional[bytes] = None,
                 fcomment: Optional[bytes] = None,
                 set_crc: bool = False):

        self.flag = 0
        self._magic = b"\x1f\x8b"
        self.method = 8
        self.mtime = mtime
        # Python isal has no 'best' compress level comparable to zlib.
        # So only medium compression or fast are supported.
        self.xfl = xfl
        self.os = os
        if data_is_ascii:
            self.flag += FTEXT
        if xtra:
            self.flag += FHEXTRA
            self._xlen = len(xtra)
            self.xtra = xtra
        if fname:
            self.flag += FNAME
            self.fname = fname
        if fcomment:
            self.flag += FCOMMENT
            self.fcomment = fcomment
        self.fhcrc = None
        if set_crc:
            self.flag += FHCRC
            self.fhcrc = isal_zlib.crc32(bytes(self))

    def __bytes__(self):
        header_bytes = self._magic[:]
        header_bytes += self.method.to_bytes(1, "little", signed=False)
        header_bytes += self.flag.to_bytes(1, "little", signed=False)
        header_bytes += self.mtime.to_bytes(4, "little", signed=False)
        header_bytes += self.xfl.to_bytes(1, "little", signed=False)
        header_bytes += self.flag.to_bytes(1, "little", signed=False)
        if self.xtra:
            header_bytes += self._xlen.to_bytes(2, "little", signed=False)
            header_bytes += self.xtra
        if self.fname:
            header_bytes += self.fname + b'\x00'
        if self.fcomment:
            header_bytes += self.fcomment + b'\x00'
        if self.fhcrc:
            header_bytes += self.fhcrc
        return header_bytes

    def __len__(self):
        return len(self.__bytes__())

    @classmethod
    def from_bytes(cls, bts: bytes):
        # Header should have at least 10 bytes
        if len(bytes) < 10:
            raise BadGzipFile("Not a gzipped file.")
        magic, method, flags, mtime, xfl, os = struct.unpack("<HBBIBB", bts[:10], )
        if magic != 0x8b1f:
            raise BadGzipFile(f"Not a gzipped file ({repr(magic)})")
        if method != 8:
            raise BadGzipFile("Unknown compression method")
        pos = 10
        if flags & FHEXTRA:
            xlen = int.from_bytes(bts[pos:pos+2], "little", signed=False)
            xtra = bts[pos+2: xlen] # Do not include null byte
            pos += xlen + 2
        if flags & FNAME:
            fname_end = bts.index(b"\x00", pos)
            fname = bts[pos:fname_end-1]
            pos = fname_end
        if flags & FCOMMENT:
            fcomment_end = bts.index(b"\x00", pos)
            fcomment = bts[pos:fcomment_end-1]
            pos = fcomment_end
        if flags & FHCRC:
            fhcrc = int.from_bytes(bts[pos:pos+2], "little", signed=False)
            fhcrc_check = isal_zlib.crc32(bts[:pos]) & 0xFFFFFFFF
            if fhcrc != fhcrc_check:
                raise BadGzipFile("Header checksum check failed")
        return cls.__new__((bts[:2], method, flags, ))

    def __len__(self):
        length = 10
        return length

# The open method was copied from the CPython source with minor adjustments.
def open(filename, mode="rb", compresslevel=_COMPRESS_LEVEL_TRADEOFF,
         encoding=None, errors=None, newline=None):
    """Open a gzip-compressed file in binary or text mode. This uses the isa-l
    library for optimized speed.

    The filename argument can be an actual filename (a str or bytes object), or
    an existing file object to read from or write to.

    The mode argument can be "r", "rb", "w", "wb", "x", "xb", "a" or "ab" for
    binary mode, or "rt", "wt", "xt" or "at" for text mode. The default mode is
    "rb", and the default compresslevel is 9.

    For binary mode, this function is equivalent to the GzipFile constructor:
    GzipFile(filename, mode, compresslevel). In this case, the encoding, errors
    and newline arguments must not be provided.

    For text mode, a GzipFile object is created, and wrapped in an
    io.TextIOWrapper instance with the specified encoding, error handling
    behavior, and line ending(s).

    """
    if "t" in mode:
        if "b" in mode:
            raise ValueError("Invalid mode: %r" % (mode,))
    else:
        if encoding is not None:
            raise ValueError(
                "Argument 'encoding' not supported in binary mode")
        if errors is not None:
            raise ValueError("Argument 'errors' not supported in binary mode")
        if newline is not None:
            raise ValueError("Argument 'newline' not supported in binary mode")

    gz_mode = mode.replace("t", "")
    # __fspath__ method is os.PathLike
    if isinstance(filename, (str, bytes)) or hasattr(filename, "__fspath__"):
        binary_file = IGzipFile(filename, gz_mode, compresslevel)
    elif hasattr(filename, "read") or hasattr(filename, "write"):
        binary_file = IGzipFile(None, gz_mode, compresslevel, filename)
    else:
        raise TypeError("filename must be a str or bytes object, or a file")

    if "t" in mode:
        return io.TextIOWrapper(binary_file, encoding, errors, newline)
    else:
        return binary_file


class IGzipFile(gzip.GzipFile):
    """The IGzipFile class simulates most of the methods of a file object with
    the exception of the truncate() method.

    This class only supports opening files in binary mode. If you need to open
    a compressed file in text mode, use the gzip.open() function.
    """
    def __init__(self, filename=None, mode=None,
                 compresslevel=isal_zlib.ISAL_DEFAULT_COMPRESSION,
                 fileobj=None, mtime=None):
        """Constructor for the IGzipFile class.

        At least one of fileobj and filename must be given a
        non-trivial value.

        The new class instance is based on fileobj, which can be a regular
        file, an io.BytesIO object, or any other object which simulates a file.
        It defaults to None, in which case filename is opened to provide
        a file object.

        When fileobj is not None, the filename argument is only used to be
        included in the gzip file header, which may include the original
        filename of the uncompressed file.  It defaults to the filename of
        fileobj, if discernible; otherwise, it defaults to the empty string,
        and in this case the original filename is not included in the header.

        The mode argument can be any of 'r', 'rb', 'a', 'ab', 'w', 'wb', 'x',
        or 'xb' depending on whether the file will be read or written.
        The default is the mode of fileobj if discernible; otherwise, the
        default is 'rb'. A mode of 'r' is equivalent to one of 'rb', and
        similarly for 'w' and 'wb', 'a' and 'ab', and 'x' and 'xb'.

        The compresslevel argument is an integer from 0 to 3 controlling the
        level of compression; 0 is fastest and produces the least compression,
        and 3 is slowest and produces the most compression. Unlike
        gzip.GzipFile 0 is NOT no compression. The default is 2.

        The mtime argument is an optional numeric timestamp to be written
        to the last modification time field in the stream when compressing.
        If omitted or None, the current time is used.
        """
        if not (isal_zlib.ISAL_BEST_SPEED <= compresslevel
                <= isal_zlib.ISAL_BEST_COMPRESSION):
            raise ValueError(
                "Compression level should be between {0} and {1}.".format(
                    isal_zlib.ISAL_BEST_SPEED, isal_zlib.ISAL_BEST_COMPRESSION
                ))
        super().__init__(filename, mode, compresslevel, fileobj, mtime)
        if self.mode == gzip.WRITE:
            self.compress = isal_zlib.compressobj(compresslevel,
                                                  isal_zlib.DEFLATED,
                                                  -isal_zlib.MAX_WBITS,
                                                  isal_zlib.DEF_MEM_LEVEL,
                                                  0)
        if self.mode == gzip.READ:
            raw = _IGzipReader(self.fileobj)
            self._buffer = io.BufferedReader(raw)

    def __repr__(self):
        s = repr(self.fileobj)
        return '<igzip ' + s[1:-1] + ' ' + hex(id(self)) + '>'

    def _write_gzip_header(self, compresslevel=_COMPRESS_LEVEL_TRADEOFF):
        # Python 3.9 added a `compresslevel` parameter to write gzip header.
        # This only determines the value of one extra flag. Because this change
        # was backported to 3.7 and 3.8 in later point versions, the attributes
        # of the function should be checked before trying to use the
        # compresslevel parameter.
        # The gzip header has an extra flag that can be set depending on the
        # compression level used. This should be set when either the fastest or
        # best method is used. ISAL level 0 is larger than gzip level 1 and
        # much faster, so setting the flag for fastest level is appropriate.
        # ISAL level 1,2 and 3 (best)are similar in size and fall around the
        # gzip level 3 size. So setting no extra flag
        # (by using COMPRESS_LEVEL_TRADEOFF) is appropriate here.
        if ("compresslevel" in super()._write_gzip_header.__code__.co_varnames
            and hasattr(gzip, "_COMPRESS_LEVEL_FAST")
                and hasattr(gzip, "_COMPRESS_LEVEL_TRADEOFF")):
            if compresslevel == _COMPRESS_LEVEL_FAST:
                super()._write_gzip_header(gzip._COMPRESS_LEVEL_FAST)
            else:
                super()._write_gzip_header(gzip._COMPRESS_LEVEL_TRADEOFF)
        else:
            super()._write_gzip_header()

    def write(self, data):
        self._check_not_closed()
        if self.mode != gzip.WRITE:
            import errno
            raise OSError(errno.EBADF, "write() on read-only IGzipFile object")

        if self.fileobj is None:
            raise ValueError("write() on closed IGzipFile object")

        if isinstance(data, bytes):
            length = len(data)
        else:
            # accept any data that supports the buffer protocol
            data = memoryview(data)
            length = data.nbytes

        if length > 0:
            self.fileobj.write(self.compress.compress(data))
            self.size += length
            self.crc = isal_zlib.crc32(data, self.crc)
            self.offset += length
        return length


class _IGzipReader(gzip._GzipReader):
    def __init__(self, fp):
        super().__init__(fp)
        self._decomp_factory = isal_zlib.decompressobj
        self._decompressor = self._decomp_factory(**self._decomp_args)

    def _add_read_data(self, data):
        # Use faster isal crc32 calculation and update the stream size in place
        # compared to CPython gzip
        self._crc = isal_zlib.crc32(data, self._crc)
        self._stream_size += len(data)


# Aliases for improved compatibility with CPython gzip module.
GzipFile = IGzipFile
_GzipReader = _IGzipReader


# Plagiarized from gzip.py from python's stdlib.
def compress(data, compresslevel=_COMPRESS_LEVEL_BEST, *, mtime=None):
    """Compress data in one shot and return the compressed string.
    Optional argument is the compression level, in range of 0-3.
    """
    buf = io.BytesIO()
    with IGzipFile(fileobj=buf, mode='wb',
                   compresslevel=compresslevel, mtime=mtime) as f:
        f.write(data)
    return buf.getvalue()


def decompress(data):
    """Decompress a gzip compressed string in one shot.
    Return the decompressed string.
    """
    with _IGzipReader(io.BytesIO(data)) as f:
        return f.read()


def main():
    parser = argparse.ArgumentParser()
    parser.description = (
        "A simple command line interface for the igzip module. "
        "Acts like igzip.")
    parser.add_argument("file", nargs="?")
    compress_group = parser.add_mutually_exclusive_group()
    compress_group.add_argument(
        "-0", "--fast", action="store_const", dest="compresslevel",
        const=_COMPRESS_LEVEL_FAST,
        help="use compression level 0 (fastest)")
    compress_group.add_argument(
        "-1", action="store_const", dest="compresslevel",
        const=1,
        help="use compression level 1")
    compress_group.add_argument(
        "-2", action="store_const", dest="compresslevel",
        const=2,
        help="use compression level 2 (default)")
    compress_group.add_argument(
        "-3", "--best", action="store_const", dest="compresslevel",
        const=_COMPRESS_LEVEL_BEST,
        help="use compression level 3 (best)")
    compress_group.add_argument(
        "-d", "--decompress", action="store_false",
        dest="compress",
        help="Decompress the file instead of compressing.")
    parser.add_argument("-c", "--stdout", action="store_true",
                        help="write on standard output")
    # -b flag not taken by either gzip or igzip. Hidden attribute. Above 32K
    # diminishing returns hit. _compression.BUFFER_SIZE = 8k. But 32K is about
    # ~6% faster.
    parser.add_argument("-b", "--buffer-size",
                        default=32 * 1024, type=int,
                        help=argparse.SUPPRESS)
    args = parser.parse_args()

    compresslevel = args.compresslevel or _COMPRESS_LEVEL_TRADEOFF

    # Determine input file
    if args.compress and args.file is None:
        in_file = sys.stdin.buffer
    elif args.compress and args.file is not None:
        in_file = io.open(args.file, mode="rb")
    elif not args.compress and args.file is None:
        in_file = IGzipFile(mode="rb", fileobj=sys.stdin.buffer)
    elif not args.compress and args.file is not None:
        base, extension = os.path.splitext(args.file)
        if extension != ".gz" and not args.stdout:
            sys.exit(f"filename doesn't end in .gz: {args.file!r}. "
                     f"Cannot determine output filename.")
        in_file = open(args.file, "rb")

    # Determine output file
    if args.compress and (args.file is None or args.stdout):
        out_file = IGzipFile(mode="wb", compresslevel=compresslevel,
                             fileobj=sys.stdout.buffer)
    elif args.compress and args.file is not None:
        out_file = open(args.file + ".gz", mode="wb",
                        compresslevel=compresslevel)
    elif not args.compress and (args.file is None or args.stdout):
        out_file = sys.stdout.buffer
    elif not args.compress and args.file is not None:
        out_file = io.open(base, "wb")

    try:
        while True:
            block = in_file.read(args.buffer_size)
            if block == b"":
                break
            out_file.write(block)
    finally:
        if in_file is not sys.stdin.buffer:
            in_file.close()
        if out_file is not sys.stdout.buffer:
            out_file.close()


if __name__ == "__main__":  # pragma: no cover
    main()
