generate-js: deps
	@find src -name '*.coffee' | xargs coffee -c -o lib

remove-js:
	@rm -fr lib/

deps:
	@test `which coffee` || echo 'You need to have CoffeeScript in your PATH.'
	@test `which pdftotext` || echo 'You need to have pdftotext in your PATH.'
	@test `which tesseract` || echo 'You need to have tesseract in your PATH.'
	@test `which gs` || echo 'You need to have gs in your PATH.'
	@test `which convert` || echo 'You need to have convert in your PATH.'
	
test: deps
	@find test -name '*_test.coffee' | xargs -n 1 -t coffee

publish: generate-js
	@test `which npm` || echo 'You need npm to do npm publish... makes sense?'
	npm publish
	@rm -fr lib/

dev: generate-js
	@coffee -wc -o lib src/*.coffee

.PHONY: all
