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

# cython: language_level=3
# cython: binding=True

"""
Implementation of the zlib module using the ISA-L libraries.
"""
###############################################################################
###       README FOR DEVELOPERS: IMPLEMENTATION OF THIS MODULE              ###
###############################################################################
#
# This module is implemented with zlibmodule.c as example. Since there is a lot
# of duplication in zlibmodule.c there is a lot of duplication in this module.
# It is not always possible to route repetitive calls to a subroutine.
# Therefore the main methods are explained here.
#
# All compress, decompress and flush implementations are basically the same.
# 1. Get a buffer from the input data
# 2. Initialise an output buffer
# 3. Initialise a isal_zstream(for compression) or inflate_state (for
#    decompression). Hereafter referred as stream.
# 4. The amount of available input bytes is set on the stream. This is either
#    the maximum amount possible (in the case the input data is equal or larger
#    than the maximum amount). Or the length of the (remaining) input data.
# 5. The amount of available output bytes is set on the stream. Buffer is
#    enlarged as needed.
# 6. inflate/deflate/flush action
# 7. Check for errors in the action.
# 8. Was the output buffer completely filled? (stream.avail_out == 0). If so go
#    to 5. Special case: decompressobj. If the output buffer is at max_length
#    continue.
# 9. Was all the input read? if not go to 4. Alternatively in the case of
#    decompression: was the end of the stream reached? if not go to 4.
# 10. In case of decompression with leftover input data. For a decompressobj
#     this is stored in unconsumed_tail / unused_data.
# 11. Convert output buffer to bytes object and return.
#
# Errors are raised in the main functions as much as possible to prevent cdef
# functions returning PyObjects that need to be transformed in C variables.
# In cases where this is not possible, C variables were set using pointers.
# Allowing repeated use of functions while limiting the number of python
# interactions.
#
###############################################################################


import warnings
import zlib

from .crc cimport crc32_gzip_refl
# Import isa-l igzip-lib C constants and functions
from .igzip_lib cimport (
    ISAL_DEF_MAX_HIST_BITS, NO_FLUSH, SYNC_FLUSH, FULL_FLUSH, IGZIP_DEFLATE,
    IGZIP_GZIP, IGZIP_ZLIB, COMP_OK, ISAL_DECOMP_OK, ISAL_BLOCK_FINISH,
    ZSTATE_END, ISAL_DEFLATE, ISAL_GZIP, ISAL_ZLIB, ISAL_DEF_MIN_LEVEL,
    ISAL_DEF_MAX_LEVEL, isal_zstream, inflate_state, isal_deflate_init,
    isal_deflate_set_dict, isal_deflate, isal_inflate_init,
    isal_inflate_set_dict, isal_inflate, isal_adler32)
# Import python-isal igzip_lib cython functions
from .igzip_lib cimport(
    check_isal_deflate_rc, check_isal_inflate_rc,
    arrange_output_buffer_with_maximum, arrange_output_buffer,
    arrange_input_buffer, MEM_LEVEL_DEFAULT_I, MEM_LEVEL_MIN_I,
    MEM_LEVEL_SMALL_I, MEM_LEVEL_MEDIUM_I, MEM_LEVEL_LARGE_I,
    MEM_LEVEL_EXTRA_LARGE_I, ISAL_DEFAULT_COMPRESSION_I, mem_level_to_bufsize,
    view_bitbuffer,)

# Alias igzip_lib compress and decompress functions
from .igzip_lib cimport _compress as igzip_compress
from .igzip_lib cimport _decompress as igzip_decompress

from . import igzip_lib
from libc.stdint cimport UINT64_MAX, UINT32_MAX
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free
from cpython.buffer cimport PyBUF_C_CONTIGUOUS, PyObject_GetBuffer, PyBuffer_Release
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.long cimport PyLong_AsUnsignedLongMask

cdef extern from "<Python.h>":
    const Py_ssize_t PY_SSIZE_T_MAX

ISAL_BEST_SPEED = igzip_lib.ISAL_BEST_SPEED
ISAL_BEST_COMPRESSION = igzip_lib.ISAL_BEST_COMPRESSION
ISAL_DEFAULT_COMPRESSION = igzip_lib.ISAL_DEFAULT_COMPRESSION
Z_BEST_SPEED = ISAL_BEST_SPEED
Z_BEST_COMPRESSION = ISAL_BEST_COMPRESSION
Z_DEFAULT_COMPRESSION = ISAL_DEFAULT_COMPRESSION

# Compile time constants with _I (for integer suffix) as names without
# suffix should be exposed to the user.
DEF DEF_BUF_SIZE_I = 16 * 1024
DEF DEF_MEM_LEVEL_I = 8

# Expose compile-time constants. Same names as zlib.
DEF_BUF_SIZE = DEF_BUF_SIZE_I
DEF_MEM_LEVEL = DEF_MEM_LEVEL_I
MAX_WBITS = igzip_lib.MAX_HIST_BITS

# Compression methods
DEFLATED = zlib.DEFLATED

# Strategies
Z_DEFAULT_STRATEGY=zlib.Z_DEFAULT_STRATEGY
Z_HUFFMAN_ONLY=zlib.Z_HUFFMAN_ONLY
Z_FILTERED=zlib.Z_FILTERED
# Following strategies not supported on all versions of zlib.
if hasattr(zlib, "Z_RLE"):
    Z_RLE = zlib.Z_RLE
if hasattr(zlib, "Z_FIXED"):
   Z_FIXED=zlib.Z_FIXED

# Flush methods
Z_NO_FLUSH=zlib.Z_NO_FLUSH
Z_SYNC_FLUSH=zlib.Z_SYNC_FLUSH
Z_FULL_FLUSH=zlib.Z_FULL_FLUSH
Z_FINISH=zlib.Z_FINISH

# Add error for compatibility
IsalError = igzip_lib.IsalError
error = IsalError


if ISAL_DEF_MAX_HIST_BITS > zlib.MAX_WBITS:
    raise  IsalError("ISAL max window size no longer compatible with zlib. "
                     "Please contact the developers.")


def adler32(data, value = 1):
    """
    Computes an Adler-32 checksum of *data*. Returns the checksum as unsigned
    32-bit integer.

    :param data: Binary data (bytes, bytearray, memoryview).
    :param value: The starting value of the checksum.
    """
    cdef unsigned long init = PyLong_AsUnsignedLongMask(value)
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    # Cython makes sure error is handled when acquiring buffer fails.
    PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
    try:
        if buffer.len > UINT64_MAX:
            raise ValueError("Data too big for adler32")
        return isal_adler32(init, <unsigned char*>buffer.buf, buffer.len)
    finally:
        PyBuffer_Release(buffer)

def crc32(data, value = 0):
    """
    Computes a CRC-32 checksum of *data*. Returns the checksum as unsigned
    32-bit integer.

    :param data: Binary data (bytes, bytearray, memoryview).
    :param value: The starting value of the checksum.
    """
    cdef unsigned long init = PyLong_AsUnsignedLongMask(value)
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    # Cython makes sure error is handled when acquiring buffer fails.
    PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
    try:
        if buffer.len > UINT64_MAX:
            raise ValueError("Data too big for adler32")
        return crc32_gzip_refl(init, <unsigned char*>buffer.buf, buffer.len)
    finally:
        PyBuffer_Release(buffer)


def compress(data,
             int level=ISAL_DEFAULT_COMPRESSION_I,
             int wbits = ISAL_DEF_MAX_HIST_BITS):
    """
    Compresses the bytes in *data*. Returns a bytes object with the
    compressed data.

    :param level: the compression level from 0 to 3. 0 is the lowest
                  compression (NOT no compression as in stdlib zlib!) and the
                  fastest. 3 is the best compression and the slowest. Default
                  is a compromise at level 2.

    :param wbits: Set the amount of history bits or window size and which
                  headers and trailers are used. Values from 9 to 15 signify
                  will use a zlib header and trailer. From +25 to +31
                  (16 + 9 to 15) a gzip header and trailer will be used.
                  -9 to -15 will generate a raw compressed string with
                  no headers and trailers.
    """
    cdef unsigned short hist_bits
    cdef unsigned short flag
    wbits_to_flag_and_hist_bits_deflate(wbits,
                                        &hist_bits,
                                        &flag)
    return igzip_compress(data, level, flag, MEM_LEVEL_DEFAULT_I, hist_bits)

def decompress(data,
                 int wbits=ISAL_DEF_MAX_HIST_BITS,
                 Py_ssize_t bufsize=DEF_BUF_SIZE,):
    """
    Deompresses the bytes in *data*. Returns a bytes object with the
    decompressed data.
    
    :param wbits: Set the amount of history bits or window size and which
                  headers and trailers are expected. Values from 8 to 15
                  will expect a zlib header and trailer. -8 to -15 will expect
                  a raw compressed string with no headers and trailers.
                  From +24 to +31 == 16 + (8 to 15) a gzip header and trailer
                  will be expected. From +40 to +47 == 32 + (8 to 15)
                  automatically detects a gzip or zlib header.
    :param bufsize: The initial size of the output buffer.
    """
    cdef unsigned int hist_bits
    cdef unsigned int flag
    wbits_to_flag_and_hist_bits_inflate(wbits,
                                        &hist_bits,
                                        &flag,
                                        data_is_gzip(data))
    return igzip_decompress(data, flag, hist_bits, bufsize)


def decompressobj(int wbits=ISAL_DEF_MAX_HIST_BITS,
                  zdict = None):
    """
    Returns a Decompress object for decompressing data streams.

    :param wbits: Set the amount of history bits or window size and which
                  headers and trailers are expected. Values from 8 to 15
                  will expect a zlib header and trailer. -8 to -15 will expect
                  a raw compressed string with no headers and trailers.
                  From +24 to +31 == 16 + (8 to 15) a gzip header and trailer
                  will be expected. From +40 to +47 == 32 + (8 to 15)
                  automatically detects a gzip or zlib header.
    :zdict:       A predefined compression dictionary. Must be the same zdict
                  as was used to compress the data.
    """
    return Decompress.__new__(Decompress, wbits, zdict)


def compressobj(int level=ISAL_DEFAULT_COMPRESSION_I,
                int method=DEFLATED,
                int wbits=ISAL_DEF_MAX_HIST_BITS,
                int memLevel=DEF_MEM_LEVEL,
                int strategy=zlib.Z_DEFAULT_STRATEGY,
                zdict = None):
    """
    Returns a Compress object for compressing data streams.

    :param level:   the compression level from 0 to 3. 0 is the lowest
                    compression (NOT no compression as in stdlib zlib!) and the
                    fastest. 3 is the best compression and the slowest. Default
                    is a compromise at level 2.
    :param method:  The compression algorithm. Currently only DEFLATED is
                    supported.
    :param wbits:   Set the amount of history bits or window size and which
                    headers and trailers are used. Values from 9 to 15 signify
                    will use a zlib header and trailer. From +25 to +31
                    (16 + 9 to 15) a gzip header and trailer will be used.
                    -9 to -15 will generate a raw compressed string with
                    no headers and trailers.
    :param memLevel: The amount of memory used for the internal compression
                     state. Higher values use more memory for better speed and
                     smaller output. Values between 1 and 9 are supported.
    :zdict:         A predefined compression dictionary. A sequence of bytes
                    that are expected to occur frequently in the to be
                    compressed data. The most common subsequences should come
                    at the end.
    """
    return Compress.__new__(Compress, level, method, wbits, memLevel, strategy, zdict)


cdef class Compress:
    """Compress object for handling streaming compression."""
    cdef isal_zstream stream
    cdef unsigned char * level_buf

    def __cinit__(self,
                  int level = ISAL_DEFAULT_COMPRESSION_I,
                  int method = DEFLATED,
                  int wbits = ISAL_DEF_MAX_HIST_BITS,
                  int memLevel = DEF_MEM_LEVEL,
                  int strategy = Z_DEFAULT_STRATEGY,
                  zdict = None):
        if strategy != Z_DEFAULT_STRATEGY:
            warnings.warn("Only one strategy is supported when using "
                          "isal_zlib. Using the default strategy.")
        isal_deflate_init(&self.stream)

        wbits_to_flag_and_hist_bits_deflate(wbits,
                                            &self.stream.hist_bits,
                                            &self.stream.gzip_flag)

        cdef Py_ssize_t zdict_length
        if zdict:
            zdict_length = len(zdict)
            if zdict_length > UINT32_MAX:
                raise OverflowError("zdict length does not fit in an unsigned int")
            err = isal_deflate_set_dict(&self.stream, zdict, zdict_length)
            if err != COMP_OK:
                check_isal_deflate_rc(err)
        self.stream.level = level
        zlib_mem_level_to_isal_bufsize(level, memLevel, &self.stream.level_buf_size)
        self.level_buf = <unsigned char *>PyMem_Malloc(self.stream.level_buf_size * sizeof(char))
        self.stream.level_buf = self.level_buf

    def __dealloc__(self):
        if self.level_buf is not NULL:
            PyMem_Free(self.level_buf)

    def compress(self, data):
        """
        Compress *data* returning a bytes object with at least part of the
        data in *data*. This data should be concatenated to the output
        produced by any preceding calls to the compress() method.
        Some input may be kept in internal buffers for later processing.
        """
        # Initialise output buffer
        cdef unsigned char * obuf = NULL
        cdef Py_ssize_t obuflen = DEF_BUF_SIZE_I

        # initialise input
        cdef Py_buffer buffer_data
        cdef Py_buffer* buffer = &buffer_data
        # Cython makes sure error is handled when acquiring buffer fails.
        PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
        cdef Py_ssize_t ibuflen = buffer.len
        self.stream.next_in = <unsigned char*>buffer.buf

        # initialise helper variables
        cdef int err
        try:
            while True:
                arrange_input_buffer(&self.stream, &ibuflen)
                while True:
                    obuflen = arrange_output_buffer(&self.stream, &obuf, obuflen)
                    if obuflen== -1:
                        raise MemoryError("Unsufficient memory for buffer allocation")
                    err = isal_deflate(&self.stream)
                    if err != COMP_OK:
                        check_isal_deflate_rc(err)
                    if self.stream.avail_out != 0:
                        break
                if self.stream.avail_in != 0:
                    raise AssertionError("Input stream should be empty")
                if ibuflen == 0:
                    break
            return PyBytes_FromStringAndSize(<char*>obuf, self.stream.next_out - obuf)
        finally:
            PyBuffer_Release(buffer)
            PyMem_Free(obuf)

    def flush(self, mode=zlib.Z_FINISH):
        """
        All pending input is processed, and a bytes object containing the
        remaining compressed output is returned.

        :param mode: Defaults to Z_FINISH which
                     finishes the compressed stream and prevents compressing
                     any more data. The other supported methods are
                     Z_NO_FLUSH, Z_SYNC_FLUSH and Z_FULL_FLUSH.
        """

        if mode == zlib.Z_NO_FLUSH:
            # Flushing with no_flush does nothing.
            return b""
        elif mode == zlib.Z_FINISH:
            self.stream.flush = FULL_FLUSH
            self.stream.end_of_stream = 1
        elif mode == zlib.Z_FULL_FLUSH:
            self.stream.flush = FULL_FLUSH
        elif mode == zlib.Z_SYNC_FLUSH:
            self.stream.flush=SYNC_FLUSH
        else:
            raise IsalError("Unsupported flush mode")

        cdef Py_ssize_t length = DEF_BUF_SIZE_I
        cdef unsigned char * obuf = NULL

        try:
            while True:
                length = arrange_output_buffer(&self.stream, &obuf, length)
                if length == -1:
                    raise MemoryError("Unsufficient memory for buffer allocation")
                err = isal_deflate(&self.stream)
                if err != COMP_OK:
                    check_isal_deflate_rc(err)
                if self.stream.avail_out != 0:
                    break
            if self.stream.avail_in != 0:
                raise AssertionError("There should be no available input after flushing.")
            return PyBytes_FromStringAndSize(<char*>obuf, self.stream.next_out - obuf)
        finally:
            PyMem_Free(obuf)

cdef class Decompress:
    """Decompress object for handling streaming decompression."""
    cdef public bytes unused_data
    cdef public bytes unconsumed_tail
    cdef public bint eof
    cdef inflate_state stream
    cdef bint method_set

    def __cinit__(self, int wbits=ISAL_DEF_MAX_HIST_BITS, zdict = None):
        isal_inflate_init(&self.stream)

        wbits_to_flag_and_hist_bits_inflate(wbits,
                                            &self.stream.hist_bits,
                                            &self.stream.crc_flag)
        if 40 <= wbits <= 47:
            self.method_set = 0
        else:
            self.method_set = 1

        cdef Py_ssize_t zdict_length
        if zdict:
            zdict_length = len(zdict)
            if zdict_length > UINT32_MAX:
                raise OverflowError("zdict length does not fit in an unsigned int")
            err = isal_inflate_set_dict(&self.stream, zdict, zdict_length)
            if err != COMP_OK:
                check_isal_deflate_rc(err)
        self.unused_data = b""
        self.unconsumed_tail = b""
        self.eof = False

    def _view_bitbuffer(self):
        """Shows the 64-bitbuffer of the internal inflate_state. It contains
        a maximum of 8 bytes. This data is already read-in so is not part
        of the unconsumed tail."""
        return view_bitbuffer(&self.stream)

    cdef save_unconsumed_input(self, Py_buffer *data):
        cdef Py_ssize_t old_size, new_size, left_size
        cdef bytes new_data
        if self.stream.block_state == ISAL_BLOCK_FINISH:
            self.eof = 1
            if self.stream.avail_in > 0:
                left_size = <unsigned char*>data.buf + data.len - self.stream.next_in
                new_data = PyBytes_FromStringAndSize(<char *>self.stream.next_in, left_size)
            else:
                new_data = b""
            if not self.unused_data:
                # The block is finished and this decompressobject can not be
                # used anymore. Some unused data is in the bitbuffer and has to
                # be recovered. Only when self.unused_data is empty. Otherwise
                # we assume the bitbuffer data is already added.
                self.unused_data = self._view_bitbuffer()
            self.unused_data += new_data
            if self.unconsumed_tail:
                self.unconsumed_tail = b""  # When there is unused_data unconsumed tail should be b""
        elif self.stream.avail_in > 0 or self.unconsumed_tail:
            left_size = <unsigned char*>data.buf + data.len - self.stream.next_in
            new_data = PyBytes_FromStringAndSize(<char *>self.stream.next_in, left_size)
            self.unconsumed_tail = new_data

    def decompress(self, data, Py_ssize_t max_length = 0):
        """
        Decompress data, returning a bytes object containing the uncompressed
        data corresponding to at least part of the data in string.

        :param max_length: if non-zero then the return value will be no longer
                           than max_length. Unprocessed data will be in the
                           unconsumed_tail attribute.
        """
   
        cdef Py_ssize_t hard_limit
        if max_length == 0:
            hard_limit = PY_SSIZE_T_MAX
        elif max_length < 0:
            raise ValueError("max_length can not be smaller than 0")
        else:
            hard_limit = max_length

        if not self.method_set:
            # Try to detect method from the first two bytes of the data.
            self.stream.crc_flag = ISAL_GZIP if data_is_gzip(data) else ISAL_ZLIB
            self.method_set = 1

        # initialise input
        cdef Py_buffer buffer_data
        cdef Py_buffer* buffer = &buffer_data
        # Cython makes sure error is handled when acquiring buffer fails.
        PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
        cdef Py_ssize_t ibuflen = buffer.len
        self.stream.next_in = <unsigned char*>buffer.buf

        cdef int err
        cdef bint max_length_reached = False
        
        # Initialise output buffer
        cdef unsigned char *obuf = NULL
        cdef Py_ssize_t obuflen = DEF_BUF_SIZE_I
        if obuflen > hard_limit:
            obuflen = hard_limit

        try:
            while True:
                arrange_input_buffer(&self.stream, &ibuflen)
                while True:
                    obuflen = arrange_output_buffer_with_maximum(
                              &self.stream, &obuf, obuflen, hard_limit)
                    if obuflen == -1:
                        raise MemoryError("Unsufficient memory for buffer allocation")
                    elif obuflen == -2:
                        max_length_reached = True
                        break
                    err = isal_inflate(&self.stream)
                    if err != ISAL_DECOMP_OK:
                        check_isal_inflate_rc(err)
                    if self.stream.block_state == ISAL_BLOCK_FINISH or self.stream.avail_out != 0:
                        break
                if self.stream.block_state == ISAL_BLOCK_FINISH or ibuflen ==0 or max_length_reached:
                    break
            self.save_unconsumed_input(buffer)
            return PyBytes_FromStringAndSize(<char*>obuf, self.stream.next_out - obuf)
        finally:
            PyBuffer_Release(buffer)
            PyMem_Free(obuf)

    def flush(self, Py_ssize_t length = DEF_BUF_SIZE):
        """
        All pending input is processed, and a bytes object containing the
        remaining uncompressed output is returned.

        :param length: The initial size of the output buffer.
        """
        if length <= 0:
            raise ValueError("Length must be greater than 0")

        cdef Py_buffer buffer_data
        cdef Py_buffer* buffer = &buffer_data
        # Cython makes sure error is handled when acquiring buffer fails.
        PyObject_GetBuffer(self.unconsumed_tail, buffer, PyBUF_C_CONTIGUOUS)
        cdef Py_ssize_t ibuflen = buffer.len
        self.stream.next_in = <unsigned char*>buffer.buf

        cdef unsigned int obuflen = length
        cdef unsigned char * obuf = NULL

        cdef int err

        try:
            while True:
                arrange_input_buffer(&self.stream, &ibuflen)
                while True:
                    obuflen = arrange_output_buffer(&self.stream, &obuf, obuflen)
                    if obuflen == -1:
                        raise MemoryError("Unsufficient memory for buffer allocation")
                    err = isal_inflate(&self.stream)
                    if err != ISAL_DECOMP_OK:
                        check_isal_inflate_rc(err)
                    if self.stream.avail_out != 0 or self.stream.block_state == ISAL_BLOCK_FINISH:
                        break
                if self.stream.block_state == ISAL_BLOCK_FINISH or ibuflen == 0:
                    break
            self.save_unconsumed_input(buffer)
            return PyBytes_FromStringAndSize(<char*>obuf, self.stream.next_out - obuf)
        finally:
            PyBuffer_Release(buffer)
            PyMem_Free(obuf)

cdef bint data_is_gzip(object data):
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
    if buffer.len < 2:
        PyBuffer_Release(buffer)
        return False
    cdef unsigned char * char_ptr = <unsigned char *>buffer.buf
    if char_ptr[0] == 31:
        if char_ptr[1] == 139:
            PyBuffer_Release(buffer)
            return True
    PyBuffer_Release(buffer)
    return False


cdef wbits_to_flag_and_hist_bits_deflate(int wbits,
                                         unsigned short * hist_bits,
                                         unsigned short * gzip_flag):
    if 9 <= wbits <= 15:  # zlib headers and trailers on compressed stream
        hist_bits[0] = wbits
        gzip_flag[0] = IGZIP_ZLIB
    elif 25 <= wbits <= 31:  # gzip headers and trailers on compressed stream
        hist_bits[0] = wbits - 16
        gzip_flag[0] = IGZIP_GZIP
    elif -15 <= wbits <= -9:  # raw compressed stream
        hist_bits[0] = -wbits
        gzip_flag[0] = IGZIP_DEFLATE
    else:
        raise ValueError("Invalid wbits value")


cdef wbits_to_flag_and_hist_bits_inflate(int wbits,
                                         unsigned int * hist_bits,
                                         unsigned int * crc_flag,
                                         bint gzip = 0):
    if wbits == 0:
        hist_bits[0] = 0
        crc_flag[0] = ISAL_ZLIB
    elif 8 <= wbits <= 15:  # zlib headers and trailers on compressed stream
        hist_bits[0] = wbits
        crc_flag[0] = ISAL_ZLIB
    elif 24 <= wbits <= 31:  # gzip headers and trailers on compressed stream
        hist_bits[0] = wbits - 16
        crc_flag[0] = ISAL_GZIP
    elif -15 <= wbits <= -8:  # raw compressed stream
        hist_bits[0] = -wbits
        crc_flag[0] = ISAL_DEFLATE
    elif 40 <= wbits <= 47:  # Accept gzip or zlib
        hist_bits[0] = wbits - 32
        crc_flag[0] = ISAL_GZIP if gzip else ISAL_ZLIB
    else:
        raise ValueError("Invalid wbits value")

cdef int zlib_mem_level_to_isal_bufsize(int compression_level, int mem_level, unsigned int *bufsize):
    """
    Convert zlib memory levels to isal equivalents
    """
    if not (1 <= mem_level <= 9):
        bufsize[0] = 0
        return -1
    if not (ISAL_DEF_MIN_LEVEL <= compression_level <= ISAL_DEF_MAX_LEVEL):
        bufsize[0] = 0
        return -1

    # If the mem_level is zlib default, return isal defaults.
    # Current zlib def level = 8. On isal the def level is large.
    # Hence 7,8 return large. 9 returns extra large.
    cdef int level = MEM_LEVEL_DEFAULT_I
    if mem_level == DEF_MEM_LEVEL_I:
        level = MEM_LEVEL_DEFAULT_I
    elif mem_level == 1:
        level = MEM_LEVEL_MIN_I
    elif mem_level in [2,3]:
        level = MEM_LEVEL_SMALL_I
    elif mem_level in [4,5,6]:
        level = MEM_LEVEL_MEDIUM_I
    elif mem_level in [7,8]:
        level = MEM_LEVEL_LARGE_I
    elif mem_level == 9:
        level = MEM_LEVEL_EXTRA_LARGE_I
    else:
        bufsize[0] = 0
        return -1
    if mem_level_to_bufsize(compression_level, level, bufsize) != 0:
        bufsize[0] = 0
        return -1
    return 0