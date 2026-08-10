FROM debian:bookworm-slim

# Runtime deps of HP's rastertospl (checked with ldd on the shipped binary).
RUN apt-get update && apt-get install -y --no-install-recommends \
      libcups2 libcupsimage2 libstdc++6 python3 \
    && rm -rf /var/lib/apt/lists/*

# Files below come from HP's Unified Linux Driver tarball and are placed here by
# install.sh. They are NOT redistributed in this repository.
#   rastertospl   - the raster -> SPL/QPDL converter
#   libscmssc.so  - HP "Smart CMS" colour engine, dlopen()ed by rastertospl
#   ppd/          - HP's PPDs and CMS colour tables
COPY rastertospl /usr/lib/cups/filter/rastertospl
COPY libscmssc.so /usr/lib/libscmssc.so

# HP's installer lays the PPDs and CMS tables out like this, and rastertospl
# builds the CMS path as "/usr/share/cups" + "/model/uld-<vendor>/cms/<prefix>".
COPY ppd /usr/share/cups/model/uld-hp
COPY splwatch.py /usr/local/bin/splwatch.py

RUN chmod 755 /usr/lib/cups/filter/rastertospl /usr/local/bin/splwatch.py && ldconfig

CMD ["python3", "-u", "/usr/local/bin/splwatch.py"]
