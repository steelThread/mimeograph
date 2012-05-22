			            ||                                                              '||
			.. .. ..   ...  .. .. ..     ....    ...     ... . ... ..   ....   ... ...   || ..
			 || || ||   ||   || || ||  .|...|| .|  '|.  || ||   ||' '' '' .||   ||'  ||  ||' ||
			 || || ||   ||   || || ||  ||      ||   ||   |''    ||     .|' ||   ||    |  ||  ||
			.|| || ||. .||. .|| || ||.  '|...'  '|..|'  '||||. .||.    '|..'|'  ||...'  .||. ||.
			                                           .|....'                  ||
			                                                                   ''''
## Description
mimeograph is a simple CoffeeScript library to extract text and create searchable
pdf files, OCRing where necessary.  Each individual step in the process is a
separate coffee-resque job allowing for interesting scaling options.

## System Requirements
- node
- redis
- poppler-utils (pdftotext)
- tesseract v3.01
- ImageMagick
- pdftk
- ruby (1.8 w/ RubyGems or 1.9)
- ruby gems:
	- pdfbeads
	- rmagick
	- hpricot

## Install Development (OS X)
Installation is a three step process:

1. install node
1. install mimeograph dependencies
1. install mimeograph

### Node
Mimeograph is currently tested with Node v0.4.8.

1. Download [node v0.4.8](http://nodejs.org/dist/node-v0.4.8.tar.gz).
1. Untar/unzip the contents and CD into the root directory (node-v0.4.8).
1. Review the installation instructions found in README.md
1. run "./configure"
1. run "make"
1. run "make install"
1. run "node -v" to verify the installation has been successful.

### Mimeo Dependencies
This assumes that you have Homebrew installed and are using it for pacakge management on OS X.  If you aren't already using it download it [here](http://mxcl.github.com/homebrew/).  If you are already using Macport, Fink or *nix use these instructions as a guide.

1. run "brew update"
1. run "brew install poppler imagemagick redis tesseract"
1. install ruby.  either via
	1. brew: "brew install ruby"
	1. [rvm](http://beginrescueend.com/)
1. run "gem install pdfbeads hpricot rmagick"
1. install [pdftk](http://www.pdflabs.com/docs/install-pdftk/)

### Mimeograph

#### Install via git
1. run "git clone git@github.com:morologous/mimeograph.git"
1. run "cd mimeograph"
1. run "make"

#### Install via npm
1. run "npm install mimeograph"

Run "npm install" with "-g" to install it in global mode.  This will install the
mimeograph module and related executables in a globally available path, such as
/usr/local.

## Running

	Usage:
	  mimeograph [OPTIONS] [ID] filename

	  -h, --help         Displays options
	  -v, --version      Shows certain's version.
	  -w, --workers      Number of workers to create. (Default: 5)
	  -s, --start        Starts a Mimeograph daemon.
	  -p, --process      Kicks of the processing of a new file.
	      --port         Redis port. (Default: Redis' default)
	      --host         Redis host. (Default: Redis' default)

	v1.3.0


	eg.  mimeograph -p test/test.pdf
	     mimeograph -w 10 -s

## License

MIT License

Copyright (c) 2011 Sean McDaniel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

#### Author: [Sean McDaniel]()
#### Author: [Jason Yankus]()
#### Author: [Carlos Fernandez]()