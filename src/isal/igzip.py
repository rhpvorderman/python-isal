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
import time
from typing import List, Optional, SupportsInt
import _compression  # noqa: I201  # Not third-party

from . import igzip_lib, isal_zlib

__all__ = ["IGzipFile", "open", "compress", "decompress", "BadGzipFile"]

_COMPRESS_LEVEL_FAST = isal_zlib.ISAL_BEST_SPEED
_COMPRESS_LEVEL_TRADEOFF = isal_zlib.ISAL_DEFAULT_COMPRESSION
_COMPRESS_LEVEL_BEST = isal_zlib.ISAL_BEST_COMPRESSION

FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT = 1, 2, 4, 8, 16

try:
    BadGzipFile = gzip.BadGzipFile  # type: ignore
except AttributeError:  # Versions lower than 3.8 do not have BadGzipFile
    BadGzipFile = OSError


# The open method was copied from the CPython source with minor adjustments.
def open(filename, mode="rb", compresslevel=_COMPRESS_LEVEL_TRADEOFF,
         encoding=None, errors=None, newline=None):
    """Open a gzip-compressed file in binary or text mode. This uses the isa-l
    library for optimized speed.

    The filename argument can be an actual filename (a str or bytes object), or
    an existing file object to read from or write to.

    The mode argument can be "r", "rb", "w", "wb", "x", "xb", "a" or "ab" for
    binary mode, or "rt", "wt", "xt" or "at" for text mode. The default mode is
    "rb", and the default compresslevel is 2.

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


class _PaddedFile(gzip._PaddedFile):
    # Overwrite _PaddedFile from gzip as its prepend method assumes that
    # the prepended data is always read from its _buffer. Unfortunately in
    # isal_zlib.decompressobj there is a bitbuffer as well which may be added.
    # So an extra check is added to prepend to ensure no extra data in front
    # of the buffer was present. (Negative self._read).
    def prepend(self, prepend=b''):
        if self._read is not None:
            # Assume data was read since the last prepend() call
            self._read -= len(prepend)
            if self._read >= 0:
                return
            # If self._read is negative the data was read further back and
            # the buffer needs to be reset.
        self._buffer = prepend
        self._length = len(self._buffer)
        self._read = 0


class _IGzipReader(gzip._GzipReader):
    def __init__(self, fp):
        # Call the init method of gzip._GzipReader's parent here.
        # It is not very invasive and allows us to override _PaddedFile
        _compression.DecompressReader.__init__(
            self, _PaddedFile(fp), igzip_lib.IgzipDecompressor,
            hist_bits=igzip_lib.MAX_HIST_BITS, flag=igzip_lib.DECOMP_DEFLATE)
        # Set flag indicating start of a new member
        self._new_member = True
        self._last_mtime = None

    def _add_read_data(self, data):
        # Use faster isal crc32 calculation and update the stream size in place
        # compared to CPython gzip
        self._crc = isal_zlib.crc32(data, self._crc)
        self._stream_size += len(data)

    def read(self, size=-1):
        if size < 0:
            return self.readall()
        # size=0 is special because decompress(max_length=0) is not supported
        if not size:
            return b""

        # For certain input data, a single
        # call to decompress() may not return
        # any data. In this case, retry until we get some data or reach EOF.
        while True:
            if self._decompressor.eof:
                # Ending case: we've come to the end of a member in the file,
                # so finish up this member, and read a new gzip header.
                # Check the CRC and file size, and set the flag so we read
                # a new member
                self._read_eof()
                self._new_member = True
                self._decompressor = self._decomp_factory(
                    **self._decomp_args)

            if self._new_member:
                # If the _new_member flag is set, we have to
                # jump to the next member, if there is one.
                self._init_read()
                if not self._read_gzip_header():
                    self._size = self._pos
                    return b""
                self._new_member = False

            # Read a chunk of data from the file
            if self._decompressor.needs_input:
                buf = self._fp.read(io.DEFAULT_BUFFER_SIZE)
                uncompress = self._decompressor.decompress(buf, size)
            else:
                uncompress = self._decompressor.decompress(b"", size)
            if self._decompressor.unused_data != b"":
                # Prepend the already read bytes to the fileobj so they can
                # be seen by _read_eof() and _read_gzip_header()
                self._fp.prepend(self._decompressor.unused_data)

            if uncompress != b"":
                break
            if buf == b"":
                raise EOFError("Compressed file ended before the "
                               "end-of-stream marker was reached")

        self._add_read_data(uncompress)
        self._pos += len(uncompress)
        return uncompress


# Aliases for improved compatibility with CPython gzip module.
GzipFile = IGzipFile
_GzipReader = _IGzipReader


def _create_simple_gzip_header(compresslevel: int,
                               mtime: Optional[SupportsInt] = None) -> bytes:
    """
    Write a simple gzip header with no extra fields.
    :param compresslevel: Compresslevel used to determine the xfl bytes.
    :param mtime: The mtime (must support conversion to a 32-bit integer).
    :return: A bytes object representing the gzip header.
    """
    if mtime is None:
        mtime = time.time()
    # There is no best compression level. ISA-L only provides algorithms for
    # fast and medium levels.
    xfl = 4 if compresslevel == _COMPRESS_LEVEL_FAST else 0
    # Pack ID1 and ID2 magic bytes, method (8=deflate), header flags (no extra
    # fields added to header), mtime, xfl and os (255 for unknown OS).
    return struct.pack("<BBBBLBB", 0x1f, 0x8b, 8, 0, int(mtime), xfl, 255)


def compress(data, compresslevel=_COMPRESS_LEVEL_BEST, *, mtime=None):
    """Compress data in one shot and return the compressed string.
    Optional argument is the compression level, in range of 0-3.
    """
    header = _create_simple_gzip_header(compresslevel, mtime)
    # use igzip_lib to compress the data without a gzip header but with a
    # gzip trailer.
    compressed = igzip_lib.compress(data, compresslevel,
                                    flag=igzip_lib.COMP_GZIP_NO_HDR)
    return header + compressed


def _gzip_header_end(data: bytes) -> int:
    """
    Find the start of the raw deflate block in a gzip file.
    :param data: Compressed data that starts with a gzip header.
    :return: The end of the header / start of the raw deflate block.
    """
    eof_error = EOFError("Compressed file ended before the end-of-stream "
                         "marker was reached")
    if len(data) < 10:
        raise eof_error
    # We are not interested in mtime, xfl and os flags.
    magic, method, flags = struct.unpack("<HBB", data[:4])
    if magic != 0x8b1f:
        raise BadGzipFile(f"Not a gzipped file ({repr(data[:2])})")
    if method != 8:
        raise BadGzipFile("Unknown compression method")
    pos = 10
    if flags & FEXTRA:
        if len(data) < pos + 2:
            raise eof_error
        xlen = int.from_bytes(data[pos: pos + 2], "little", signed=False)
        pos += 2 + xlen
    if flags & FNAME:
        pos = data.find(b"\x00", pos) + 1
        # pos will be -1 + 1 when null byte not found.
        if not pos:
            raise eof_error
    if flags & FCOMMENT:
        pos = data.find(b"\x00", pos) + 1
        if not pos:
            raise eof_error
    if flags & FHCRC:
        if len(data) < pos + 2:
            raise eof_error
        header_crc = int.from_bytes(data[pos: pos + 2], "little", signed=False)
        # CRC is stored as a 16-bit integer by taking last bits of crc32.
        crc = isal_zlib.crc32(data[:pos]) & 0xFFFF
        if header_crc != crc:
            raise BadGzipFile(f"Corrupted header. Checksums do not "
                              f"match: {crc} != {header_crc}")
        pos += 2
    return pos


def decompress(data):
    """Decompress a gzip compressed string in one shot.
    Return the decompressed string.
    """
    all_blocks: List[bytes] = []
    while True:
        if data == b"":
            break
        header_end = _gzip_header_end(data)
        do = isal_zlib.decompressobj(-15)
        block = do.decompress(data[header_end:]) + do.flush()
        if not do.eof or len(do.unused_data) < 8:
            raise EOFError("Compressed file ended before the end-of-stream "
                           "marker was reached")
        checksum, length = struct.unpack("<II", do.unused_data[:8])
        crc = isal_zlib.crc32(block)
        if crc != checksum:
            raise BadGzipFile("CRC check failed")
        if length != len(block):
            raise BadGzipFile("Incorrect length of data produced")
        all_blocks.append(block)
        # Remove all padding null bytes and start next block.
        data = do.unused_data[8:].lstrip(b"\x00")
    return b"".join(all_blocks)


def _argument_parser():
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
    compress_group.set_defaults(compress=True)
    compress_group.add_argument(
        "-d", "--decompress", action="store_const",
        dest="compress",
        const=False,
        help="Decompress the file instead of compressing.")
    parser.add_argument("-c", "--stdout", action="store_true",
                        help="write on standard output")
    # -b flag not taken by either gzip or igzip. Hidden attribute. Above 32K
    # diminishing returns hit. _compression.BUFFER_SIZE = 8k. But 32K is about
    # ~6% faster.
    parser.add_argument("-b", "--buffer-size",
                        default=32 * 1024, type=int,
                        help=argparse.SUPPRESS)
    return parser


def main():
    args = _argument_parser().parse_args()

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
