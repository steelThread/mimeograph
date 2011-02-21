			            ||                                                              '||      
			.. .. ..   ...  .. .. ..     ....    ...     ... . ... ..   ....   ... ...   || ..   
			 || || ||   ||   || || ||  .|...|| .|  '|.  || ||   ||' '' '' .||   ||'  ||  ||' ||  
			 || || ||   ||   || || ||  ||      ||   ||   |''    ||     .|' ||   ||    |  ||  ||  
			.|| || ||. .||. .|| || ||.  '|...'  '|..|'  '||||. .||.    '|..'|'  ||...'  .||. ||. 
			                                           .|....'                  ||               
			                                                                   ''''              
## Description
mimeograph is a simple CoffeeScript library to extract text from a PDF, OCRing where necessary.  None of the 
actual PDF operation is performed by the CoffeeScript, everything is farmed out to pdftotext, imagemagick 
and tesseract.

## System Requirements
- poppler-utils (pdftotext)
- tesseract
- ImageMagick

## Install

	$ git clone git@github.com:morologous/mimeograph.git
	$ cd mimeograph
	$ make link
	
## Running
	Usage:
	  mimeograph [OPTIONS] filename

	Available options:
	  -h, --help         Displays options
	  -v, --version      Shows certain's version.
	  -w, --workers      Number of workers to create. Ex.: 5 (default)

	v0.1.0
	
	eg.  mimeograph ./test/test.pdf
    
## Dependencies
Most dependencies will be fetched for you with the link target.  However coffee-resque has yet to be bumped in the npm registry. 