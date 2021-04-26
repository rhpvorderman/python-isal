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
Pythonic interface to ISA-L's igzip_lib.

This module comes with the following constants:

============================== ================================================
``ISAL_BEST_SPEED``            The lowest compression level (0)
``ISAL_BEST_COMPRESSION``      The highest compression level (3)
 ``ISAL_DEFAULT_COMPRESSION``  The compromise compression level (2)
``DEF_BUF_SIZE``               Default size for the starting buffer (16K)
``MAX_HIST_BITS``              Maximum window size bits (15).
``COMP_DEFLATE``               Flag to compress to a raw deflate block
``COMP_GZIP``                  Flag to compress a gzip block, consisting of a
                               gzip header, raw deflate block and a gzip
                               trailer.
``COMP_GZIP_NO_HDR``           Flag to compress a gzip block without a header.
``COMP_ZLIB``                  Flag to compress a zlib block, consisting of a
                               zlib header, a raw deflate block and a zlib
                               trailer.
``COMP_ZLIB_NO_HDR``           Flag to compress a zlib block without a header.
``DECOMP_DEFLATE``             Flag to decompress a raw deflate block.
``DECOMP_GZIP``                Flag to decompress a gzip block including header
                               and verify the checksums in the trailer.
``DECOMP_GZIP_NO_HDR``         Flag to decompress a gzip block without a header
                               and verify the checksums in the trailer.
``DECOMP_GZIP_NO_HDR_VER``     Flag to decompress a gzip block without a header
                               and without verifying the checksums in the
                               trailer.
``DECOMP_ZLIB``                Flag to decompress a zlib block including header
                               and verify the checksums in the trailer.
``DECOMP_ZLIB_NO_HDR``         Flag to decompress a zlib block without a header
                               and verify the checksums in the trailer.
``DECOMP_ZLIB_NO_HDR_VER``     Flag to decompress a zlib block without a header
                               and without verifying the checksums in the
                               trailer.
``MEM_LEVEL_DEFAULT``          The default memory level for the internal level
                               buffer. (Equivalent to
                               MEM_LEVEL_LARGE.)
``MEM_LEVEL_MIN``              The minimum memory level.
``MEM_LEVEL_SMALL``
``MEM_LEVEL_MEDIUM``
``MEM_LEVEL_LARGE``
``MEM_LEVEL_EXTRA_LARGE``      The largest memory level.
============================== ================================================
"""

from libc.stdint cimport UINT64_MAX, UINT32_MAX
from libc.string cimport memmove, memcpy
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free
from cpython.buffer cimport PyBUF_C_CONTIGUOUS, PyObject_GetBuffer, PyBuffer_Release
from cpython.bytes cimport PyBytes_FromStringAndSize

cdef extern from "<Python.h>":
    const Py_ssize_t PY_SSIZE_T_MAX

ISAL_BEST_SPEED = ISAL_DEF_MIN_LEVEL
ISAL_BEST_COMPRESSION = ISAL_DEF_MAX_LEVEL
cdef int ISAL_DEFAULT_COMPRESSION_I = 2
ISAL_DEFAULT_COMPRESSION = ISAL_DEFAULT_COMPRESSION_I

DEF DEF_BUF_SIZE_I = 16 * 1024
DEF_BUF_SIZE = DEF_BUF_SIZE_I
MAX_HIST_BITS = ISAL_DEF_MAX_HIST_BITS

ISAL_NO_FLUSH = NO_FLUSH
ISAL_SYNC_FLUSH = SYNC_FLUSH
ISAL_FULL_FLUSH = FULL_FLUSH

COMP_DEFLATE = IGZIP_DEFLATE
COMP_GZIP = IGZIP_GZIP
COMP_GZIP_NO_HDR = IGZIP_GZIP_NO_HDR
COMP_ZLIB = IGZIP_ZLIB
COMP_ZLIB_NO_HDR = IGZIP_ZLIB_NO_HDR

DECOMP_DEFLATE = ISAL_DEFLATE
DECOMP_GZIP = ISAL_GZIP
DECOMP_GZIP_NO_HDR = ISAL_GZIP_NO_HDR
DECOMP_ZLIB = ISAL_ZLIB
DECOMP_ZLIB_NO_HDR = ISAL_ZLIB_NO_HDR
DECOMP_ZLIB_NO_HDR_VER = ISAL_ZLIB_NO_HDR_VER
DECOMP_GZIP_NO_HDR_VER = ISAL_GZIP_NO_HDR_VER

cdef int MEM_LEVEL_DEFAULT_I = 0
cdef int MEM_LEVEL_MIN_I = 1
cdef int MEM_LEVEL_SMALL_I = 2
cdef int MEM_LEVEL_MEDIUM_I = 3
cdef int MEM_LEVEL_LARGE_I = 4
cdef int MEM_LEVEL_EXTRA_LARGE_I = 5
MEM_LEVEL_DEFAULT = MEM_LEVEL_DEFAULT_I
MEM_LEVEL_MIN = MEM_LEVEL_MIN_I
MEM_LEVEL_SMALL = MEM_LEVEL_SMALL_I
MEM_LEVEL_MEDIUM = MEM_LEVEL_MEDIUM_I
MEM_LEVEL_LARGE = MEM_LEVEL_LARGE_I
MEM_LEVEL_EXTRA_LARGE = MEM_LEVEL_EXTRA_LARGE_I

class IsalError(OSError):
    """Exception raised on compression and decompression errors."""
    pass



cdef Py_ssize_t arrange_output_buffer_with_maximum(stream_or_state *stream,
                                                   unsigned char **buffer,
                                                   Py_ssize_t length,
                                                   Py_ssize_t max_length):
    # The zlibmodule.c function builds a PyBytes object. A unsigned char *
    # is build here because building raw PyObject * stuff in cython is somewhat
    # harder due to cython's interference. FIXME
    cdef Py_ssize_t occupied
    cdef Py_ssize_t new_length
    cdef unsigned char * new_buffer
    if buffer[0] == NULL:
        buffer[0] = <unsigned char*>PyMem_Malloc(length * sizeof(char))
        if buffer[0] == NULL:
            return -1
        occupied = 0
    else:
        occupied = stream.next_out - buffer[0]
        if length == occupied:
            if length == max_length:
                return -2
            if length <= max_length >> 1:
                new_length = length << 1
            else:
                new_length = max_length
            new_buffer = <unsigned char *>PyMem_Realloc(buffer[0], new_length)
            if new_buffer == NULL:
                return -1
            buffer[0] = new_buffer
            length = new_length
    stream.avail_out = <unsigned int>py_ssize_t_min(length - occupied, UINT32_MAX)
    stream.next_out = buffer[0] + occupied
    return length

cdef Py_ssize_t arrange_output_buffer(stream_or_state *stream,
                                      unsigned char **buffer,
                                      Py_ssize_t length):
    cdef Py_ssize_t ret
    ret = arrange_output_buffer_with_maximum(stream, buffer, length, PY_SSIZE_T_MAX)
    if ret == -2:  # Maximum reached.
        return -1
    return ret

cdef void arrange_input_buffer(stream_or_state *stream, Py_ssize_t *remains):
    stream.avail_in = <unsigned int>py_ssize_t_min(remains[0], UINT32_MAX)
    remains[0] -= stream.avail_in

def compress(data,
             int level=ISAL_DEFAULT_COMPRESSION_I,
             int flag = IGZIP_DEFLATE,
             int mem_level = MEM_LEVEL_DEFAULT_I,
             int hist_bits = ISAL_DEF_MAX_HIST_BITS,
            ):
    """
    Compresses the bytes in *data*. Returns a bytes object with the
    compressed data.

    :param level: the compression level from 0 to 3. 0 is the lowest
                  compression (NOT no compression as in stdlib zlib!) and the
                  fastest. 3 is the best compression and the slowest. Default
                  is a compromise at level 2.
    :param flag:  Controls the header and trailer. Can be any of: COMP_DEFLATE
                  (default), COMP_GZIP, COMP_GZIP_NO_HDR, COMP_ZLIB, 
                  COMP_ZLIB_NO_HDR.
    :param mem_level: Set the memory level for the memory buffer. Larger
                      buffers improve performance. Can be any of: 
                      MEM_LEVEL_DEFAULT (default, 
                      equivalent to MEM_LEVEL_LARGE), MEM_LEVEL_MIN, 
                      MEM_LEVEL_SMALL, MEM_LEVEL_MEDIUM, MEM_LEVEL_LARGE,
                      MEM_LEVEL_EXTRA_LARGE.
    :param hist_bits: Sets the size of the view window. The size equals 
                      2^hist_bits. Similar to zlib wbits value, except that 
                      hist_bits is not used to set the compression flag.
                      This is best left at the default (15, maximum).
    """
    return _compress(data, level, flag, mem_level, hist_bits)


cdef _compress(data,
             int level,
             int flag,
             int mem_level,
             int hist_bits,
            ):
    # Initialise stream
    cdef isal_zstream stream
    cdef unsigned int level_buf_size
    mem_level_to_bufsize(level, MEM_LEVEL_DEFAULT_I, &level_buf_size)
    cdef unsigned char* level_buf = <unsigned char*> PyMem_Malloc(level_buf_size * sizeof(char))
    isal_deflate_init(&stream)
    stream.level = level
    stream.level_buf = level_buf
    stream.level_buf_size = level_buf_size
    stream.hist_bits = hist_bits
    stream.gzip_flag = flag

    # Initialise output buffer
    cdef Py_ssize_t bufsize = DEF_BUF_SIZE_I
    cdef unsigned char * obuf = NULL
    
    # initialise input
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    # Cython makes sure error is handled when acquiring buffer fails.
    PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
    cdef Py_ssize_t ibuflen = buffer.len
    stream.next_in = <unsigned char*>buffer.buf

    # initialise helper variables
    cdef int err

    try:
        while True:
            arrange_input_buffer(&stream, &ibuflen)
            if ibuflen == 0:
                stream.flush = FULL_FLUSH
                stream.end_of_stream = 1
            else:
                stream.flush = NO_FLUSH

            while True:
                bufsize = arrange_output_buffer(&stream, &obuf, bufsize)
                if bufsize == -1:
                    raise MemoryError("Unsufficient memory for buffer allocation")
                err = isal_deflate(&stream)
                if err != COMP_OK:
                    check_isal_deflate_rc(err)
                if stream.avail_out != 0:
                    break
            if stream.avail_in != 0:
                raise AssertionError("Input stream should be empty")
            if stream.internal_state.state == ZSTATE_END:
                break
        return PyBytes_FromStringAndSize(<char*>obuf, stream.next_out - obuf)
    finally:
        PyBuffer_Release(buffer)
        PyMem_Free(level_buf)
        PyMem_Free(obuf)


def decompress(data,
                 int flag = ISAL_DEFLATE,
                 int hist_bits=ISAL_DEF_MAX_HIST_BITS,
                 Py_ssize_t bufsize=DEF_BUF_SIZE):
    """
    Deompresses the bytes in *data*. Returns a bytes object with the
    decompressed data.

    :param flag: Whether the compressed block contains headers and/or trailers
                 and of which type. Can be any of: DECOMP_DEFLATE (default), 
                 DECOMP_GZIP, DECOMP_GZIP_NO_HDR, DECOMP_GZIP_NO_HDR_VER,
                 DECOMP_ZLIB, DECOMP_ZLIB_NO_HDR, DECOMP_ZLIB_NO_HDR_VER.
    :param hist_bits: Sets the size of the view window. The size equals 
                      2^hist_bits. Similar to zlib wbits value, except that 
                      hist_bits is not used to set the compression flag.
                      This is best left at the default (15, maximum).
    :param bufsize: The initial size of the output buffer. The output buffer
                    is dynamically resized according to the need. The default
                    size is 16K. If a larger output is expected, using a 
                    larger buffer will improve performance by negating the 
                    costs associated with the dynamic resizing.
    """
    return _decompress(data, flag, hist_bits, bufsize)


cdef _decompress(data,
                 int flag,
                 int hist_bits,
                 Py_ssize_t bufsize):
    if bufsize < 0:
        raise ValueError("bufsize must be non-negative")
   
    cdef inflate_state stream
    isal_inflate_init(&stream)
    stream.hist_bits = hist_bits
    stream.crc_flag = flag

    # initialise input
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    # Cython makes sure error is handled when acquiring buffer fails.
    PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
    cdef Py_ssize_t ibuflen = buffer.len
    stream.next_in =  <unsigned char*>buffer.buf

    # Initialise output buffer
    cdef unsigned char * obuf = NULL
    cdef int err

    try:
        while True:
            arrange_input_buffer(&stream, &ibuflen)

            while True:
                bufsize = arrange_output_buffer(&stream, &obuf, bufsize)
                if bufsize == -1:
                    raise MemoryError("Unsufficient memory for buffer allocation")
                err = isal_inflate(&stream)
                if err != ISAL_DECOMP_OK:
                    check_isal_inflate_rc(err)
                if stream.avail_out != 0:
                    break
            if ibuflen == 0 or stream.block_state == ISAL_BLOCK_FINISH:
                break
        if stream.block_state != ISAL_BLOCK_FINISH:
            raise IsalError("incomplete or truncated stream")
        return PyBytes_FromStringAndSize(<char*>obuf, stream.next_out - obuf)
    finally:
        PyBuffer_Release(buffer)
        PyMem_Free(obuf)


cdef bytes view_bitbuffer(inflate_state * stream):

        cdef int bits_in_buffer = stream.read_in_length
        cdef int read_in_length = bits_in_buffer // 8
        if read_in_length == 0:
            return b""
        cdef int remainder = bits_in_buffer % 8
        read_in = stream.read_in
        # The bytes are added by bitshifting, so in reverse order. Reading the
        # 64-bit integer into 8 bytes little-endian provides the characters in
        # the correct order.
        return (read_in >> remainder).to_bytes(8, "little")[:read_in_length]


cdef class IgzipDecompressor:
    """Decompress object for handling streaming decompression."""
    cdef public bytes unused_data
    cdef public bint eof
    cdef public bint needs_input
    cdef inflate_state stream
    cdef unsigned char * input_buffer
    cdef size_t input_buffer_size
    cdef Py_ssize_t avail_in_real

    def __dealloc__(self):
        if self.input_buffer != NULL:
            PyMem_Free(self.input_buffer)

    def __cinit__(self,
                  flag=ISAL_DEFLATE,
                  hist_bits=ISAL_DEF_MAX_HIST_BITS,
                  zdict = None):
        isal_inflate_init(&self.stream)

        self.stream.hist_bits = hist_bits
        self.stream.crc_flag = flag
        cdef Py_ssize_t zdict_length
        if zdict:
            zdict_length = len(zdict)
            if zdict_length > UINT32_MAX:
                raise OverflowError("zdict length does not fit in an unsigned int")
            err = isal_inflate_set_dict(&self.stream, zdict, zdict_length)
            if err != COMP_OK:
                check_isal_deflate_rc(err)
        self.unused_data = b""
        self.eof = False
        self.input_buffer = NULL
        self.input_buffer_size = 0
        self.avail_in_real = 0
        self.needs_input = True
        
    def _view_bitbuffer(self):
        """Shows the 64-bitbuffer of the internal inflate_state. It contains
        a maximum of 8 bytes. This data is already read-in so is not part
        of the unconsumed tail."""
        return view_bitbuffer(&self.stream)

    cdef decompress_buf(self, Py_ssize_t max_length, unsigned char ** obuf):
        obuf[0] = NULL
        cdef Py_ssize_t obuflen = DEF_BUF_SIZE_I
        cdef int err
        if obuflen > max_length:
            obuflen = max_length
        while True:
            obuflen = arrange_output_buffer_with_maximum(&self.stream, obuf, obuflen, max_length)
            if obuflen == -1:
                raise MemoryError("Unsufficient memory for buffer allocation")
            elif obuflen == -2:
                break
            arrange_input_buffer(&self.stream, &self.avail_in_real)
            err = isal_inflate(&self.stream)
            self.avail_in_real += self.stream.avail_in
            if err != ISAL_DECOMP_OK:
                check_isal_inflate_rc(err)
            if self.stream.block_state == ISAL_BLOCK_FINISH:
                self.eof = 1
                break
            elif self.avail_in_real == 0:
                break
        return

    def decompress(self, data, Py_ssize_t max_length = -1):
        """
        Decompress data, returning a bytes object containing the uncompressed
        data corresponding to at least part of the data in string.

        :param data: Binary data (bytes, bytearray, memoryview).
        :param max_length: if non-zero then the return value will be no longer
                           than max_length.
        """
        if self.eof:
            raise EOFError("End of stream already reached")
        cdef bint input_buffer_in_use
        
        cdef Py_ssize_t hard_limit
        if max_length < 0:
            hard_limit = PY_SSIZE_T_MAX
        else:
            hard_limit = max_length

        cdef unsigned int avail_now
        cdef unsigned int avail_total
        # Cython makes sure error is handled when acquiring buffer fails.
        cdef Py_buffer buffer_data
        cdef Py_buffer* buffer = &buffer_data
        PyObject_GetBuffer(data, buffer, PyBUF_C_CONTIGUOUS)
        cdef Py_ssize_t ibuflen = buffer.len
        cdef unsigned char * data_ptr = <unsigned char*>buffer.buf


        cdef bint max_length_reached = False
        cdef unsigned char * tmp
        cdef size_t offset
        # Initialise output buffer
        cdef unsigned char *obuf = NULL

        try:
            if self.stream.next_in != NULL:
                avail_now = (self.input_buffer + self.input_buffer_size) - \
                            (self.stream.next_in + self.avail_in_real)
                avail_total = self.input_buffer_size - self.avail_in_real
                if avail_total < ibuflen:
                    offset = self.stream.next_in - self.input_buffer
                    new_size = self.input_buffer_size + ibuflen - avail_now
                    tmp = <unsigned char*>PyMem_Realloc(self.input_buffer, new_size)
                    if tmp == NULL:
                        raise MemoryError()
                    self.input_buffer = tmp
                    self.input_buffer_size = new_size
                    self.stream.next_in = self.input_buffer + offset
                elif avail_now < ibuflen:
                    memmove(self.input_buffer, self.stream.next_in,
                            self.avail_in_real)
                    self.stream.next_in = self.input_buffer
                memcpy(<void *>(self.stream.next_in + self.avail_in_real), data_ptr, buffer.len)
                self.avail_in_real += ibuflen
                input_buffer_in_use = 1
            else:
                self.stream.next_in = data_ptr
                self.avail_in_real = ibuflen
                input_buffer_in_use = 0

            self.decompress_buf(hard_limit, &obuf)
            if obuf == NULL:
                self.stream.next_in = NULL
                return b""
            if self.eof:
                self.needs_input = False
                if self.avail_in_real > 0:
                    new_data = PyBytes_FromStringAndSize(<char *>self.stream.next_in, self.avail_in_real)
                    self.unused_data = self._view_bitbuffer() + new_data
            elif self.avail_in_real == 0:
                self.stream.next_in = NULL
                self.needs_input = True
            else:
                self.needs_input = False
                if not input_buffer_in_use:
                    # Discard buffer if to small.
                    # Resizing may needlessly copy the current contents.
                    if self.input_buffer != NULL and self.input_buffer_size < self.avail_in_real:
                        PyMem_Free(self.input_buffer)
                        self.input_buffer = NULL

                    # Allocate of necessary
                    if self.input_buffer == NULL:
                        self.input_buffer = <unsigned char *>PyMem_Malloc(self.avail_in_real)
                        if self.input_buffer == NULL:
                            raise MemoryError()
                        self.input_buffer_size = self.avail_in_real

                    # Copy tail
                    memcpy(self.input_buffer, self.stream.next_in, self.avail_in_real)
                    self.stream.next_in = self.input_buffer
            return PyBytes_FromStringAndSize(<char*>obuf, self.stream.next_out - obuf)
        except:
            self.stream.next_in = NULL
            raise
        finally:
            PyBuffer_Release(buffer)
            PyMem_Free(obuf)


cdef int mem_level_to_bufsize(int compression_level, int mem_level, unsigned int *bufsize):
    """
    Convert zlib memory levels to isal equivalents
    """
    if not (0 <= mem_level <= MEM_LEVEL_EXTRA_LARGE_I):
        bufsize[0] = 0
        return -1
    if not (ISAL_DEF_MIN_LEVEL <= compression_level <= ISAL_DEF_MAX_LEVEL):
        bufsize[0] = 0
        return -1

    if mem_level == MEM_LEVEL_DEFAULT_I:
        if compression_level == 0:
            bufsize[0] = ISAL_DEF_LVL0_DEFAULT
        elif compression_level == 1:
            bufsize[0] = ISAL_DEF_LVL1_DEFAULT
        elif compression_level == 2:
            bufsize[0] = ISAL_DEF_LVL2_DEFAULT
        elif compression_level == 3:
            bufsize[0] = ISAL_DEF_LVL3_DEFAULT
    elif mem_level == MEM_LEVEL_MIN_I:
        if compression_level == 0:
            bufsize[0] = ISAL_DEF_LVL0_MIN
        elif compression_level == 1:
            bufsize[0] = ISAL_DEF_LVL1_MIN
        elif compression_level == 2:
            bufsize[0] = ISAL_DEF_LVL2_MIN
        elif compression_level == 3:
            bufsize[0] = ISAL_DEF_LVL3_MIN
    elif mem_level == MEM_LEVEL_SMALL_I:
        if compression_level == 0:
            bufsize[0] = ISAL_DEF_LVL0_SMALL
        elif compression_level == 1:
            bufsize[0] = ISAL_DEF_LVL1_SMALL
        elif compression_level == 2:
            bufsize[0] = ISAL_DEF_LVL2_SMALL
        elif compression_level == 3:
            bufsize[0] = ISAL_DEF_LVL3_SMALL
    elif mem_level == MEM_LEVEL_MEDIUM_I:
        if compression_level == 0:
            bufsize[0] = ISAL_DEF_LVL0_MEDIUM
        elif compression_level == 1:
            bufsize[0] = ISAL_DEF_LVL1_MEDIUM
        elif compression_level == 2:
            bufsize[0] = ISAL_DEF_LVL2_MEDIUM
        elif compression_level == 3:
            bufsize[0] = ISAL_DEF_LVL3_MEDIUM
    elif mem_level == MEM_LEVEL_LARGE_I:
        if compression_level == 0:
            bufsize[0] = ISAL_DEF_LVL0_LARGE
        elif compression_level == 1:
            bufsize[0] = ISAL_DEF_LVL1_LARGE
        elif compression_level == 2:
            bufsize[0] = ISAL_DEF_LVL2_LARGE
        elif compression_level == 3:
            bufsize[0] = ISAL_DEF_LVL3_LARGE
    elif mem_level == MEM_LEVEL_EXTRA_LARGE_I:
        if compression_level == 0:
            bufsize[0] = ISAL_DEF_LVL0_EXTRA_LARGE
        elif compression_level == 1:
            bufsize[0] = ISAL_DEF_LVL1_EXTRA_LARGE
        elif compression_level == 2:
            bufsize[0] = ISAL_DEF_LVL2_EXTRA_LARGE
        elif compression_level == 3:
            bufsize[0] = ISAL_DEF_LVL3_EXTRA_LARGE
    return 0

cdef check_isal_deflate_rc(int rc):
    if rc == COMP_OK:
        return
    elif rc == INVALID_FLUSH:
        raise IsalError("Invalid flush type")
    elif rc == INVALID_PARAM:
        raise IsalError("Invalid parameter")
    elif rc == STATELESS_OVERFLOW:
        raise IsalError("Not enough room in output buffer")
    elif rc == ISAL_INVALID_OPERATION:
        raise IsalError("Invalid operation")
    elif rc == ISAL_INVALID_STATE:
        raise IsalError("Invalid state")
    elif rc == ISAL_INVALID_LEVEL:
        raise IsalError("Invalid compression level.")
    elif rc == ISAL_INVALID_LEVEL_BUF:
        raise IsalError("Level buffer too small.")
    else:
        raise IsalError("Unknown Error")

cdef check_isal_inflate_rc(int rc):
    if rc >= ISAL_DECOMP_OK:
        return
    if rc == ISAL_END_INPUT:
        raise IsalError("End of input reached")
    if rc == ISAL_OUT_OVERFLOW:
        raise IsalError("End of output reached")
    if rc == ISAL_NAME_OVERFLOW:
        raise IsalError("End of gzip name buffer reached")
    if rc == ISAL_COMMENT_OVERFLOW:
        raise IsalError("End of gzip name buffer reached")
    if rc == ISAL_EXTRA_OVERFLOW:
        raise IsalError("End of extra buffer reached")
    if rc == ISAL_NEED_DICT:
        raise IsalError("Dictionary needed to continue")
    if rc == ISAL_INVALID_BLOCK:
        raise IsalError("Invalid deflate block found")
    if rc == ISAL_INVALID_SYMBOL:
        raise IsalError("Invalid deflate symbol found")
    if rc == ISAL_INVALID_LOOKBACK:
        raise IsalError("Invalid lookback distance found")
    if rc == ISAL_INVALID_WRAPPER:
        raise IsalError("Invalid gzip/zlib wrapper found")
    if rc == ISAL_UNSUPPORTED_METHOD:
        raise IsalError("Gzip/zlib wrapper specifies unsupported compress method")
    if rc == ISAL_INCORRECT_CHECKSUM:
        raise IsalError("Incorrect checksum found")