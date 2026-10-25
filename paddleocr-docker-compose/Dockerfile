# Paddle's sm_120 image ships paddleocr with the doc-parser extra, which does
# not include python-docx, yet `doc_parser` save_all() always tries to write a
# .docx -> ModuleNotFoundError after the markdown/json have been saved.
# Adding it here keeps the CLI usable and the image reproducible.
#
# USER root matters: the base image runs as `paddleocr`, so a plain pip install
# would land in /home/paddleocr/.local and be invisible to the wrapper, which
# runs the container as the host uid with HOME=/tmp. System site-packages only.
#
# The base is pinned by digest; `latest-nvidia-gpu-sm120` is what that digest was
# called when this was written (2026-10). This image is the Blackwell/sm_120
# build: cu126 wheels have no sm_120 kernels.
FROM ccr-2vdh3abv-pub.cnc.bj.baidubce.com/paddlepaddle/paddleocr-vl@sha256:659eb236d509966380c0ac938049cbb3494f1e84c5d5c53fcac3572c05463487

USER root
RUN python -m pip install --no-cache-dir "python-docx>=1.1" \
 && python -c "import docx; print('python-docx', docx.__version__)"

USER paddleocr
