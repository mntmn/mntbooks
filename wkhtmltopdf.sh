#!/bin/bash
xvfb-run -a -s "-screen 0 640x480x32" wkhtmltopdf "$@"
