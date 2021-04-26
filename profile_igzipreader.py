import cProfile
import sys

from isal import igzip


def main():
    igzip.READ_BUFFER_SIZE = 32 * 1024
    with igzip.open(sys.argv[1], mode="rb") as gzip_h:
        while True:
            block = gzip_h.read(32*1024)
            if block == b"":
                return


if __name__ == "__main__":
    cProfile.run("main()")
