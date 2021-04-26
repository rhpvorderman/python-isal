.. python-isal documentation master file, created by
   sphinx-quickstart on Fri Sep 11 15:42:56 2020.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

=======================================
Welcome to python-isal's documentation!
=======================================

.. toctree::
   :maxdepth: 2
   :caption: Contents:

============
Introduction
============

.. include:: includes/README.rst
   :start-after: .. introduction start
   :end-before: .. introduction end

==========
Quickstart
==========

.. include:: includes/README.rst
   :start-after: .. quickstart start
   :end-before: .. quickstart end

============
Installation
============
Installation with pip
---------------------

::

    pip install isal

Installation is supported on Linux, MacOS and Windows. On most platforms
wheels are provided.
The installation will include a staticallly linked version of ISA-L.
If a wheel is not provided for your system the
installation will build ISA-L first in a temporary directory. Please check the
`ISA-L homepage <https://github.com/intel/isa-l>`_ for the build requirements.

The latest development version of python-isal can be installed with::

    pip install git+https://github.com/rhpvorderman/python-isal.git

This requires having the build requirements installed.
If you wish to link
dynamically against a version of libisal installed on your system use::

     PYTHON_ISAL_LINK_DYNAMIC=true pip install isal --no-binary isal

ISA-L is available in numerous Linux distro's as well as on conda via the
conda-forge channel. Checkout the `ports documentation
<https://github.com/intel/isa-l/wiki/Ports--Repos>`_ on the ISA-L project wiki
to find out how to install it. It is important that the development headers
are also installed.

On Debian and Ubuntu the ISA-L libraries (including the development headers)
can be installed with::

  sudo apt install libisal-dev

Installation via conda
----------------------
Python-isal can be installed via conda, for example using
the `miniconda <https://docs.conda.io/en/latest/miniconda.html>`_ installer
with a properly setup `conda-forge
<https://conda-forge.org/docs/user/introduction.html#how-can-i-install-packages-from-conda-forge>`_
channel. When used with bioinformatics tools setting up `bioconda
<http://bioconda.github.io/user/install.html#install-conda>`_
provides a clear set of installation instructions for conda.

python-isal is available on conda-forge and can be installed with::

  conda install python-isal

This will automatically install the ISA-L library dependency as well, since
it is available on conda-forge.

.. _differences-with-zlib-and-gzip-modules:

======================================
Differences with zlib and gzip modules
======================================

.. include:: includes/README.rst
   :start-after: .. differences start
   :end-before: .. differences end

============================
API Documentation: isal_zlib
============================

.. automodule:: isal.isal_zlib
   :members:

========================
API-documentation: igzip
========================

.. automodule:: isal.igzip
   :members: compress, decompress, open, BadGzipFile, GzipFile, READ_BUFFER_SIZE

   .. autoclass:: IGzipFile
      :members:
      :special-members: __init__

============================
API Documentation: igzip_lib
============================

.. automodule:: isal.igzip_lib
   :members:

==========================
python -m isal.igzip usage
==========================

.. argparse::
   :module: isal.igzip
   :func: _argument_parser
   :prog: python -m isal.igzip


============
Contributing
============
.. include:: includes/README.rst
   :start-after: .. contributing start
   :end-before: .. contributing end

================
Acknowledgements
================
.. include:: includes/README.rst
   :start-after: .. acknowledgements start
   :end-before: .. acknowledgements end

.. include:: includes/CHANGELOG.rst
