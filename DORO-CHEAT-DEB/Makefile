PACKAGE_SCHEME ?= roothide
.PHONY: package validate source
package:
	bash scripts/build-deb.sh $(PACKAGE_SCHEME)
validate:
	python3 scripts/validate-project.py
	python3 scripts/verify-protection.py
	python3 scripts/verify-runtime-payload.py
	python3 scripts/source-manifest.py
source:
	python3 scripts/source-archive.py
