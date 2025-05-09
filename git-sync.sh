#!/bin/bash
cd /root
git add *.sh *.py
git commit -m "Auto nightly sync" 2>/dev/null
git push origin main
