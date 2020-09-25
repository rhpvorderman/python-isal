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


import warnings
import zlib

from .crc cimport crc32_gzip_refl
from .igzip_lib cimport *
from libc.stdint cimport UINT64_MAX, UINT32_MAX, uint32_t
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cpython.buffer cimport PyBUF_READ, PyBUF_C_CONTIGUOUS, PyObject_GetBuffer, \
    PyBuffer_Release
from cpython.bytes cimport PyBytes_FromStringAndSize, _PyBytes_Resize
from cpython.object cimport PyObject

cdef extern from "<Python.h>":
    const Py_ssize_t PY_SSIZE_T_MAX
    cdef char* PyBytes_AS_STRING(PyObject * string)

ISAL_BEST_SPEED = ISAL_DEF_MIN_LEVEL
ISAL_BEST_COMPRESSION = ISAL_DEF_MAX_LEVEL
ISAL_DEFAULT_COMPRESSION = 2
Z_BEST_SPEED = ISAL_BEST_SPEED
Z_BEST_COMPRESSION = ISAL_BEST_COMPRESSION
Z_DEFAULT_COMPRESSION = ISAL_DEFAULT_COMPRESSION
cdef int ISAL_DEFAULT_COMPRESSION_I = ISAL_DEFAULT_COMPRESSION
cdef int ZLIB_DEFAULT_COMPRESSION_I = zlib.Z_DEFAULT_COMPRESSION

DEF_BUF_SIZE = zlib.DEF_BUF_SIZE
DEF_MEM_LEVEL = zlib.DEF_MEM_LEVEL
cdef int DEF_MEM_LEVEL_I = zlib.DEF_MEM_LEVEL # Can not be manipulated by user.
MAX_WBITS = ISAL_DEF_MAX_HIST_BITS
ISAL_DEFAULT_HIST_BITS=0

# Compression methods
DEFLATED = zlib.DEFLATED

# Strategies
Z_DEFAULT_STRATEGY=zlib.Z_DEFAULT_STRATEGY
Z_RLE=zlib.Z_RLE 
Z_HUFFMAN_ONLY=zlib.Z_HUFFMAN_ONLY
Z_FILTERED=zlib.Z_FILTERED
Z_FIXED=zlib.Z_FIXED

# Flush methods
ISAL_NO_FLUSH=NO_FLUSH 
ISAL_SYNC_FLUSH=SYNC_FLUSH 
ISAL_FULL_FLUSH=FULL_FLUSH

Z_NO_FLUSH=ISAL_NO_FLUSH
Z_SYNC_FLUSH=ISAL_SYNC_FLUSH
Z_FULL_FLUSH=ISAL_FULL_FLUSH
Z_FINISH=ISAL_FULL_FLUSH

class IsalError(OSError):
    pass

# Add error for compatibility
error = IsalError


if ISAL_DEF_MAX_HIST_BITS > zlib.MAX_WBITS:
    raise  IsalError("ISAL max window size no longer compatible with zlib. "
                     "Please contact the developers.")


cpdef adler32(data, unsigned int value = 1):
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    if PyObject_GetBuffer(data, buffer, PyBUF_READ & PyBUF_C_CONTIGUOUS) != 0:
        raise TypeError("Failed to get buffer")
    try:
        if buffer.len > UINT64_MAX:
            raise ValueError("Data too big for adler32")
        return isal_adler32(value, <unsigned char*>buffer.buf, buffer.len)
    finally:
        PyBuffer_Release(buffer)

cpdef crc32(data, unsigned int value = 0):
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    if PyObject_GetBuffer(data, buffer, PyBUF_READ & PyBUF_C_CONTIGUOUS) != 0:
        raise TypeError("Failed to get buffer")
    try:
        if buffer.len > UINT64_MAX:
            raise ValueError("Data too big for adler32")
        return crc32_gzip_refl(value, <unsigned char*>buffer.buf, buffer.len)
    finally:
        PyBuffer_Release(buffer)

cdef Py_ssize_t Py_ssize_t_min(Py_ssize_t a, Py_ssize_t b):
    if a <= b:
        return a
    else:
        return b

ctypedef fused stream_or_state:
    isal_zstream
    inflate_state

cdef unsigned int unsigned_int_min(unsigned int a, unsigned int b):
    if a <= b:
        return a
    else:
        return b

cdef void arrange_input_buffer(stream_or_state *stream, Py_ssize_t *remains):
    stream.avail_in = unsigned_int_min(<unsigned int>remains[0], UINT32_MAX)
    remains[0] -= stream.avail_in

cdef Py_ssize_t arrange_output_buffer_with_maximum(
    stream_or_state *stream,
    PyObject **buffer,
    Py_ssize_t length,
    Py_ssize_t max_length):

    cdef Py_ssize_t occupied
    cdef Py_ssize_t new_length

    if buffer[0] == NULL:
        new_buffer = PyBytes_FromStringAndSize(NULL, length)
        buffer[0] = <PyObject *>new_buffer
        if (buffer[0] == NULL):
            return -1
        occupied=0
    else:
        occupied = stream.next_out - <unsigned char*>PyBytes_AS_STRING(buffer[0])
        if length == occupied:
            assert length <= max_length
            if length == max_length:
                return -2
            if length <= (max_length >> 1):
                new_length = length << 1
            else:
                new_length = max_length
            if (_PyBytes_Resize(buffer, new_length) < 0):
                return -1
            length = new_length

    stream.avail_out = unsigned_int_min(<unsigned int>(length-occupied), UINT32_MAX)
    stream.next_out = <unsigned char *>PyBytes_AS_STRING(buffer[0]) + occupied

    return length

cdef Py_ssize_t arrange_output_buffer(isal_zstream *stream,
                                             PyObject **buffer,
                                             Py_ssize_t length):

    cdef Py_ssize_t ret
    ret = arrange_output_buffer_with_maximum(stream, buffer, length,
                                             PY_SSIZE_T_MAX)
    if ret == -2:
        raise MemoryError()
    return ret

def compress(data,
             int level=ISAL_DEFAULT_COMPRESSION_I,
             int wbits = ISAL_DEF_MAX_HIST_BITS):
    if level == ZLIB_DEFAULT_COMPRESSION_I:
        level = ISAL_DEFAULT_COMPRESSION_I

    # Initialise stream
    cdef isal_zstream stream
    cdef unsigned int level_buf_size = zlib_mem_level_to_isal(level, DEF_MEM_LEVEL)
    cdef unsigned char* level_buf = <unsigned char*> PyMem_Malloc(level_buf_size * sizeof(char))
    isal_deflate_init(&stream)
    stream.level = level
    stream.level_buf = level_buf
    stream.level_buf_size = level_buf_size
    wbits_to_flag_and_hist_bits_deflate(wbits,
                                        &stream.hist_bits,
                                        &stream.gzip_flag)

    # Initialise output buffer
    cdef unsigned int obuflen = DEF_BUF_SIZE
    cdef unsigned char * obuf = <unsigned char*> PyMem_Malloc(obuflen * sizeof(char))
    out = []
    
    # initialise input
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    if PyObject_GetBuffer(data, buffer, PyBUF_READ & PyBUF_C_CONTIGUOUS) != 0:
        raise TypeError("Failed to get buffer")
    cdef Py_ssize_t ibuflen = buffer.len
    cdef unsigned char * ibuf = <unsigned char*>buffer.buf
    stream.next_in = ibuf

    # initialise helper variables
    cdef int err

    # Implementation imitated from CPython's zlibmodule.c
    try:
        while stream.internal_state.state != ZSTATE_END or ibuflen !=0:
            # This loop runs n times (at least twice). n-1 times to fill the input
            # buffer with data. The nth time the input is empty. In that case
            # stream.flush is set to FULL_FLUSH and the end_of_stream is activated.
            arrange_input_buffer(&stream, &ibuflen)
            if ibuflen == 0:
                stream.flush = FULL_FLUSH
                stream.end_of_stream = 1
            else:
                stream.flush = NO_FLUSH

            # This loop reads all the input bytes. The check is at the end,
            # because when flush = FULL_FLUSH the input buffer is empty. But
            # this loop still needs to run one time.
            while True:
                stream.next_out = obuf  # Reset output buffer.
                stream.avail_out = obuflen
                err = isal_deflate(&stream)
                if err != COMP_OK:
                    # There is some python interacting when possible exceptions
                    # Are raised. So we remain in pure C code if we check for
                    # COMP_OK first.
                    check_isal_deflate_rc(err)
                # Instead of output buffer resizing as the zlibmodule.c example
                # the data is appended to a list.
                # TODO: Improve this with the buffer protocol.
                out.append(obuf[:obuflen - stream.avail_out])
                if stream.avail_in == 0:
                    break
        return b"".join(out)
    finally:
        PyBuffer_Release(buffer)
        PyMem_Free(level_buf)
        PyMem_Free(obuf)

cpdef decompress(data,
                 int wbits=ISAL_DEF_MAX_HIST_BITS,
                 Py_ssize_t bufsize=DEF_BUF_SIZE,):

    if bufsize < 0:
        raise ValueError("bufsize must be non-negative")
   
    cdef inflate_state stream
    isal_inflate_init(&stream)

    wbits_to_flag_and_hist_bits_inflate(wbits,
                                        &stream.hist_bits,
                                        &stream.crc_flag)

    # initialise input
    cdef Py_buffer buffer_data
    cdef Py_buffer* buffer = &buffer_data
    if PyObject_GetBuffer(data, buffer, PyBUF_READ & PyBUF_C_CONTIGUOUS) != 0:
        raise TypeError("Failed to get buffer")
    cdef Py_ssize_t ibuflen = buffer.len
    cdef unsigned char * ibuf = <unsigned char*>buffer.buf
    stream.next_in = ibuf

    # Initialise output buffer
    cdef unsigned int obuflen = bufsize
    cdef unsigned char * obuf = <unsigned char*> PyMem_Malloc(obuflen * sizeof(char))
    out = []
    cdef int err

    # Implementation imitated from CPython's zlibmodule.c
    try:
        while ibuflen != 0 or stream.block_state != ISAL_BLOCK_FINISH:
            arrange_input_buffer(&stream, &ibuflen)

            # This loop reads all the input bytes. The check is at the end,
            # because when the block state is not at FINISH, the function needs
            # to be called again.
            while True:
                stream.next_out = obuf  # Reset output buffer.
                stream.avail_out = obuflen
                err = isal_inflate(&stream)
                if err != ISAL_DECOMP_OK:
                    # There is some python interacting when possible exceptions
                    # Are raised. So we remain in pure C code if we check for
                    # COMP_OK first.
                    check_isal_inflate_rc(err)
                # Instead of output buffer resizing as the zlibmodule.c example
                # the data is appended to a list.
                # TODO: Improve this with the buffer protocol.
                out.append(obuf[:obuflen - stream.avail_out])
                if stream.avail_in == 0:
                    break

            # When nothing was written, stop.
            if stream.avail_out == obuflen:
                break
        if stream.block_state != ISAL_BLOCK_FINISH:
            raise IsalError("incomplete or truncated stream")
        return b"".join(out)
    finally:
        PyBuffer_Release(buffer)
        PyMem_Free(obuf)


cpdef decompressobj(int wbits=ISAL_DEF_MAX_HIST_BITS,
                  zdict = None):
    return Decompress.__new__(Decompress, wbits, zdict)


cpdef compressobj(int level=ISAL_DEFAULT_COMPRESSION,
                  int method=DEFLATED,
                  int wbits=ISAL_DEF_MAX_HIST_BITS,
                  int memLevel=DEF_MEM_LEVEL,
                  int strategy=zlib.Z_DEFAULT_STRATEGY,
                  zdict = None):
    return Compress.__new__(Compress, level, method, wbits, memLevel, strategy, zdict)


cdef class Compress:
    cdef isal_zstream stream
    cdef unsigned char * level_buf
    cdef unsigned char * obuf
    cdef unsigned int obuflen

    def __cinit__(self,
                  int level = ISAL_DEFAULT_COMPRESSION,
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
        if level == ZLIB_DEFAULT_COMPRESSION_I:
            level = ISAL_DEFAULT_COMPRESSION_I
        self.stream.level = level
        self.stream.level_buf_size = zlib_mem_level_to_isal(level, memLevel)
        self.level_buf = <unsigned char *>PyMem_Malloc(self.stream.level_buf_size * sizeof(char))
        self.stream.level_buf = self.level_buf

        self.obuflen = DEF_BUF_SIZE
        self.obuf = <unsigned char *>PyMem_Malloc(self.obuflen * sizeof(char))

    def __dealloc__(self):
        if self.obuf is not NULL:
            PyMem_Free(self.obuf)
        if self.level_buf is not NULL:
            PyMem_Free(self.level_buf)

    def compress(self, data):
        # Initialise output buffer
        out = []

        # initialise input
        cdef Py_buffer buffer_data
        cdef Py_buffer* buffer = &buffer_data
        if PyObject_GetBuffer(data, buffer, PyBUF_READ & PyBUF_C_CONTIGUOUS) != 0:
            raise TypeError("Failed to get buffer")
        cdef Py_ssize_t ibuflen = buffer.len
        cdef unsigned char * ibuf = <unsigned char*>buffer.buf
        self.stream.next_in = ibuf

        # initialise helper variables
        cdef int err
        try:
            while ibuflen !=0:
                # This loop runs n times (at least twice). n-1 times to fill the input
                # buffer with data. The nth time the input is empty. In that case
                # stream.flush is set to FULL_FLUSH and the end_of_stream is activated.
                arrange_input_buffer(&self.stream, &ibuflen)
                while self.stream.avail_in != 0:
                    self.stream.next_out = self.obuf  # Reset output buffer.
                    self.stream.avail_out = self.obuflen
                    err = isal_deflate(&self.stream)
                    if err != COMP_OK:
                        # There is some python interacting when possible exceptions
                        # Are raised. So we remain in pure C code if we check for
                        # COMP_OK first.
                        check_isal_deflate_rc(err)
                    # Instead of output buffer resizing as the zlibmodule.c example
                    # the data is appended to a list.
                    # TODO: Improve this with the buffer protocol.
                    out.append(self.obuf[:self.obuflen - self.stream.avail_out])
            return b"".join(out)
        finally:
            PyBuffer_Release(buffer)

    def flush(self, int mode=FULL_FLUSH):
        if mode == NO_FLUSH:
            # Flushing with no_flush does nothing.
            return b""

        # Initialise stream
        self.stream.flush = mode
        self.stream.end_of_stream = 1
         # Initialise output buffer
        out = []
       
        while self.stream.internal_state.state != ZSTATE_END:
            self.stream.next_out = self.obuf  # Reset output buffer.
            self.stream.avail_out = self.obuflen
            err = isal_deflate(&self.stream)
            if err != COMP_OK:
                # There is some python interacting when possible exceptions
                # Are raised. So we remain in pure C code if we check for
                # COMP_OK first.
                check_isal_deflate_rc(err)
            # Instead of output buffer resizing as the zlibmodule.c example
            # the data is appended to a list.
            # TODO: Improve this with the buffer protocol.
            out.append(self.obuf[:self.obuflen - self.stream.avail_out])
        return b"".join(out)

cdef class Decompress:
    cdef public bytes unused_data
    cdef public bytes unconsumed_tail
    cdef public bint eof
    cdef bint is_initialised
    cdef inflate_state stream
    cdef unsigned char * obuf
    cdef unsigned int obuflen

    def __cinit__(self, wbits=ISAL_DEF_MAX_HIST_BITS, zdict = None):
        isal_inflate_init(&self.stream)

        wbits_to_flag_and_hist_bits_inflate(wbits,
                                            &self.stream.hist_bits,
                                            &self.stream.crc_flag)

        cdef Py_ssize_t zdict_length
        if zdict:
            zdict_length = len(zdict)
            if zdict_length > UINT32_MAX:
                raise OverflowError("zdict length does not fit in an unsigned int")
            err = isal_inflate_set_dict(&self.stream, zdict, zdict_length)
            if err != COMP_OK:
                check_isal_deflate_rc(err)
        self.obuflen = DEF_BUF_SIZE
        self.unused_data = b""
        self.unconsumed_tail = b""
        self.eof = 0
        self.is_initialised = 1

    cdef save_unconsumed_input(self, Py_buffer *data):
        cdef Py_ssize_t old_size, new_size, left_size
        cdef bytes new_data
        if self.stream.block_state == ISAL_BLOCK_FINISH:
            self.eof = 1
            if self.stream.avail_in > 0:
                old_size = len(self.unused_data)
                left_size = <unsigned char*>data.buf + data.len - self.stream.next_in
                if left_size > (PY_SSIZE_T_MAX - old_size):
                    raise MemoryError()
                new_data = PyBytes_FromStringAndSize(<char *>self.stream.next_in, left_size)
                self.unused_data += new_data
        if self.stream.avail_in > 0 or self.unconsumed_tail:
            left_size = <unsigned char*>data.buf + data.len - self.stream.next_in
            new_data = PyBytes_FromStringAndSize(<char *>self.stream.next_in, left_size)
            self.unconsumed_tail = new_data

    def decompress(self, data, Py_ssize_t max_length = 0):
   
        cdef Py_ssize_t total_bytes = 0
        if max_length == 0:
            max_length = PY_SSIZE_T_MAX
        elif max_length < 0:
            raise ValueError("max_length can not be smaller than 0")

        # initialise input
        cdef Py_buffer buffer_data
        cdef Py_buffer* buffer = &buffer_data
        if PyObject_GetBuffer(data, buffer, PyBUF_READ & PyBUF_C_CONTIGUOUS) != 0:
            raise TypeError("Failed to get buffer")
        cdef Py_ssize_t ibuflen = buffer.len
        cdef unsigned char * ibuf = <unsigned char*>buffer.buf
        self.stream.next_in = ibuf
        self.stream.avail_out = 0
        cdef unsigned int prev_avail_out
        cdef unsigned int bytes_written
        cdef Py_ssize_t unused_bytes
        cdef int err
        
        # Initialise output buffer
        cdef unsigned char * obuf = <unsigned char*> PyMem_Malloc(self.obuflen * sizeof(char))
        out = []

        cdef bint last_round = 0
        try:
            # This loop reads all the input bytes. If there are no input bytes
            # anymore the output is written.
            while True:
                arrange_input_buffer(&self.stream, &ibuflen)
                while (self.stream.avail_out == 0 or self.stream.avail_in != 0):
                    self.stream.next_out = obuf  # Reset output buffer.
                    if total_bytes >= max_length:
                        break
                    elif total_bytes + self.obuflen >= max_length:
                        self.stream.avail_out =  max_length - total_bytes
                        # The inflate process may not fill all available bytes so
                        # we make sure this is the last round.
                        last_round = 1
                    else:
                        self.stream.avail_out = self.obuflen
                    prev_avail_out = self.stream.avail_out
                    err = isal_inflate(&self.stream)
                    if err != ISAL_DECOMP_OK:
                        # There is some python interacting when possible exceptions
                        # Are raised. So we remain in pure C code if we check for
                        # COMP_OK first.
                        check_isal_inflate_rc(err)
                    bytes_written = prev_avail_out - self.stream.avail_out
                    total_bytes += bytes_written
                    out.append(obuf[:bytes_written])
                    if self.stream.block_state == ISAL_BLOCK_FINISH or last_round:
                        break
                if self.stream.block_state == ISAL_BLOCK_FINISH or ibuflen ==0:
                    break
            self.save_unconsumed_input(buffer)
            return b"".join(out)
        finally:
            PyMem_Free(obuf)
            PyBuffer_Release(buffer)

    def flush(self, Py_ssize_t length = DEF_BUF_SIZE):
        if length <= 0:
            raise ValueError("Length must be greater than 0")
        if length > UINT32_MAX:
            raise ValueError("Length should not be larger than 4GB.")
        cdef Py_buffer buffer_data
        cdef Py_buffer* buffer = &buffer_data
        if PyObject_GetBuffer(self.unconsumed_tail, buffer, PyBUF_READ & PyBUF_C_CONTIGUOUS) != 0:
            raise TypeError("Failed to get buffer")
        cdef Py_ssize_t ibuflen = buffer.len
        cdef unsigned char * ibuf = <unsigned char*>buffer.buf
        self.stream.next_in = ibuf

        cdef unsigned int total_bytes = 0
        cdef unsigned int bytes_written
        out = []
        cdef unsigned int obuflen = length
        cdef unsigned char * obuf = <unsigned char *>PyMem_Malloc(obuflen * sizeof(char))
        cdef Py_ssize_t unused_bytes

        try:
            while self.stream.block_state != ISAL_BLOCK_FINISH and ibuflen !=0:
                arrange_input_buffer(&self.stream, &ibuflen)
                while (self.stream.block_state != ISAL_BLOCK_FINISH):
                    self.stream.next_out = obuf  # Reset output buffer.
                    self.stream.avail_out = obuflen
                    err = isal_inflate(&self.stream)
                    if err != ISAL_DECOMP_OK:
                        # There is some python interacting when possible exceptions
                        # Are raised. So we remain in pure C code if we check for
                        # COMP_OK first.
                        check_isal_inflate_rc(err)
                    # Instead of output buffer resizing as the zlibmodule.c example
                    # the data is appended to a list.
                    # TODO: Improve this with the buffer protocol.
                    bytes_written = obuflen - self.stream.avail_out
                    total_bytes += bytes_written
                    out.append(obuf[:bytes_written])
            self.save_unconsumed_input(buffer)
            return b"".join(out)
        finally:
            PyMem_Free(obuf)

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
                                         unsigned int * crc_flag):
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
    else:
        raise ValueError("Invalid wbits value")

cdef zlib_mem_level_to_isal(int compression_level, int mem_level):
    """
    Convert zlib memory levels to isal equivalents
    """
    if not (1 <= mem_level <= 9):
        raise ValueError("Memory level must be between 1 and 9")
    if not (ISAL_DEF_MIN_LEVEL <= compression_level <= ISAL_DEF_MAX_LEVEL):
        raise ValueError("Invalid compression level.")

    # If the mem_level is zlib default, return isal defaults.
    # Current zlib def level = 8. On isal the def level is large.
    # Hence 7,8 return large. 9 returns extra large.
    if mem_level == DEF_MEM_LEVEL_I:
        if compression_level == 0:
            return ISAL_DEF_LVL0_DEFAULT
        elif compression_level == 1:
            return ISAL_DEF_LVL1_DEFAULT
        elif compression_level == 2:
            return ISAL_DEF_LVL2_DEFAULT
        elif compression_level == 3:
            return ISAL_DEF_LVL3_DEFAULT
    if mem_level == 1:
        if compression_level == 0:
            return ISAL_DEF_LVL0_MIN
        elif compression_level == 1:
            return ISAL_DEF_LVL1_MIN
        elif compression_level == 2:
            return ISAL_DEF_LVL2_MIN
        elif compression_level == 3:
            return ISAL_DEF_LVL3_MIN
    elif mem_level in [2,3]:
        if compression_level == 0:
            return ISAL_DEF_LVL0_SMALL
        elif compression_level == 1:
            return ISAL_DEF_LVL1_SMALL
        elif compression_level == 2:
            return ISAL_DEF_LVL2_SMALL
        elif compression_level == 3:
            return ISAL_DEF_LVL3_SMALL
    elif mem_level in [4,5,6]:
        if compression_level == 0:
            return ISAL_DEF_LVL0_MEDIUM
        elif compression_level == 1:
            return ISAL_DEF_LVL1_MEDIUM
        elif compression_level == 2:
            return ISAL_DEF_LVL2_MEDIUM
        elif compression_level == 3:
            return ISAL_DEF_LVL3_MEDIUM
    elif mem_level in [7,8]:
        if compression_level == 0:
            return ISAL_DEF_LVL0_LARGE
        elif compression_level == 1:
            return ISAL_DEF_LVL1_LARGE
        elif compression_level == 2:
            return ISAL_DEF_LVL2_LARGE
        elif compression_level == 3:
            return ISAL_DEF_LVL3_LARGE
    elif mem_level == 9:
        if compression_level == 0:
            return ISAL_DEF_LVL0_EXTRA_LARGE
        elif compression_level == 1:
            return ISAL_DEF_LVL1_EXTRA_LARGE
        elif compression_level == 2:
            return ISAL_DEF_LVL2_EXTRA_LARGE
        elif compression_level == 3:
            return ISAL_DEF_LVL3_EXTRA_LARGE
    raise ValueError("Incorrect memory level or compression level.")

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
