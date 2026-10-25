# dance-songs

A personal toolbox of personal tools. It is public, but it is a toolbox I use,
not a product — there is no support promise and no roadmap.

The name is a reference to Pink Floyd's compilation *A Collection of Great Dance
Songs*, which contains no songs suitable for dancing and whose cover shows two
dancers chained to the ground. This is the joke, and it ends here: every tool
below is named for what it literally does.

## Tools

| Tool | What it does | Needs |
| --- | --- | --- |
| [`paddleocr-docker-compose`](paddleocr-docker-compose/) | Converts scanned PDFs to markdown, JSON and DOCX with PaddleOCR-VL, GPU-pinned, in Docker Compose | Linux/WSL2, Docker Compose 2.30+, an NVIDIA GPU |

Each tool directory is self-contained: its own `compose.yaml`, its own scripts,
its own README. Nothing at the repo root is required to run a tool.

## Licence

MIT. See [LICENSE](LICENSE).
