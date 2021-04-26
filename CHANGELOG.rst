==========
Changelog
==========

.. Newest changes should be on top.

.. This document is user facing. Please word the changes in such a way
.. that users understand how the changes affect the new version.

version 0.11.0-dev
------------------
In this release the ``python -m isal.igzip`` relatively slow decompression rate
has been improved. Previously it was 19% slower than ``igzip`` when used with
the ``-d`` flag for decompressing, now it is just 8% slower.

+ Reverse a bug in the build system which caused some docstring and parameter
  information on ``igzip_lib`` and ``isal_zlib`` to disappear in the
  documentation and the REPL.
+ Increase the buffer size for ``python -m isal.igzip`` so it is now closer
  to speeds reached with ``igzip``.
+ Add a ``READ_BUFFER_SIZE`` attribute to ``igzip`` which allows setting the
  amount of raw data that is read at once.
+ Add an ``igzip_lib.IgzipDecompressor`` object which can decompress without
  using an unconsumed_tail and is therefore more efficient.

version 0.10.0
------------------
+ Added an ``igzip_lib`` module which allows more direct access to ISA-L's
  igzip_lib API. This allows features such as headerless compression and
  decompression, as well as setting the memory levels manually.
+ Added more extensive documentation.

version 0.9.0
-----------------
+ Fix a bug where a AttributeError was triggered when zlib.Z_RLE or
  zlib.Z_FIXED were not present.
+ Add support for Linux aarch64 builds.
+ Add support for pypy by adding pypy tests to the CI and setting up wheel
  building support.

version 0.8.1
-----------------
+ Fix a bug where multi-member gzip files where read incorrectly due to an
  offset error. This was caused by ISA-L's decompressobj having a small
  bitbuffer which was not taken properly into account in some circumstances.

version 0.8.0
-----------------
+ Speed up ``igzip.compress`` and ``igzip.decompress`` by improving the
  implementation.
+ Make sure compiler arguments are passed to ISA-L compilation step. Previously
  ISA-L was compiled without optimisation steps, causing the statically linked
  library to be significantly slower.
+ A unused constant from the ``isal_zlib`` library was removed:
  ``ISAL_DEFAULT_HIST_BITS``.
+ Refactor isal_zlib.pyx to work almost the same as zlibmodule.c. This has made
  the code look cleaner and has reduced some overhead.

version 0.7.0
-----------------
+ Remove workarounds in the ``igzip`` module for the ``unconsumed_tail``
  and ``unused_data`` bugs. ``igzip._IGzipReader`` now functions the same
  as ``gzip._GzipReader`` with only a few calls replaced with ``isal_zlib``
  calls for speed.
+ Correctly implement ``unused_data`` and ``unconsumed_tail`` on
  ``isal_zlib.Decompress`` objects.
  It works the same as in CPython's zlib now.
+ Correctly implement flush implementation on ``isal_zlib.Compress`` and
  ``isal_zlib.Decompress`` objects.
  It works the same as in CPython's zlib now.

version 0.6.1
-----------------
+ Fix a crash that occurs when opening a file that did not end in ``.gz`` while
  outputting to stdout using ``python -m isal.igzip``.

version 0.6.0
-----------------
+ ``python -m gzip``'s behaviour has been changed since fixing bug:
  `bpo-43316 <https://bugs.python.org/issue43316>`_. This bug was not present
  in ``python -m isal.igzip`` but it handled the error differently than the
  solution in CPython. This is now corrected and ``python -m isal.igzip``
  handles the error the same as the fixed ``python -m gzip``.
+ Installation on Windows is now supported. Wheels are provided for Windows as
  well.

version 0.5.0
-----------------
+ Fix a bug where negative integers were not allowed for the ``adler32`` and
  ``crc32`` functions in ``isal_zlib``.
+ Provided stubs (type-hint files) for ``isal_zlib`` and ``_isal`` modules.
  Package is now tested with mypy to ensure correct type information.
+ The command-line interface now reads in blocks of 32K instead of 8K. This
  improves performance by about 6% when compressing and 11% when decompressing.
  A hidden ``-b`` flag was added to adjust the buffer size for benchmarks.
+ A ``-c`` or ``--stdout`` flag was added to the CLI interface of isal.igzip.
  This allows it to behave more like the ``gzip`` or ``pigz`` command line
  interfaces.

version 0.4.0
-----------------
+ Move wheel building to cibuildwheel on github actions CI. Wheels are now
  provided for Mac OS as well.
+ Make a tiny change in setup.py so python-isal can be build on Mac OS X.

version 0.3.0
-----------------
+ Set included ISA-L library at version 2.30.0.
+ Python-isal now comes with a source distribution of ISA-L in its source
  distribution against which python-isal is linked statically upon installation
  by default. Dynamic linking against system libraries is now optional. Wheels
  with the statically linked ISA-L are now provided on PyPI.

version 0.2.0
-----------------
+ Fixed a bug where writing of the gzip header would crash if an older version
  of Python 3.7 was used such as on Debian or Ubuntu. This is due to
  differences between point releases because of a backported feature. The code
  now checks if the backported feature is present.
+ Added Python 3.9 to the testing.
+ Fixed ``setup.py`` to list setuptools as a requirement.
+ Changed homepage to reflect move to pycompression organization.

version 0.1.0
-----------------
+ Publish API documentation on readthedocs.
+ Add API documentation.
+ Ensure the igzip module is fully compatible with the gzip stdlib module.
+ Add compliance tests from CPython to ensure isal_zlib and igzip are validated
  to the same standards as the zlib and gzip modules.
+ Added a working gzip app using ``python -m isal.igzip``
+ Add test suite that tests all possible settings for functions on the
  isal_zlib module.
+ Create igzip module which implements all gzip functions and methods.
+ Create isal_zlib module which implements all zlib functions and methods.
