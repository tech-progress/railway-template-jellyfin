FROM sigoden/dufs:v0.47.0@sha256:e5152c04e41d5a9d785546278b632bf035c8a08c52d7e8d35f4b59681f5ff35a AS dufs
FROM jellyfin/jellyfin:12.4@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771
COPY --from=dufs /bin/dufs /usr/local/bin/dufs
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint
RUN chmod 0755 /usr/local/bin/railway-entrypoint
# Railway attaches one volume per service, so Jellyfin's data, cache and the
# media libraries all live under /data.
ENV JELLYFIN_DATA_DIR=/data/jellyfin \
    JELLYFIN_CONFIG_DIR=/data/jellyfin/config \
    JELLYFIN_LOG_DIR=/data/jellyfin/log \
    JELLYFIN_CACHE_DIR=/data/cache \
    XDG_CACHE_HOME=/data/cache \
    UPLOAD_PORT=5001 \
    DOTNET_gcServer=0
# ASP.NET's default Server GC sizes its heaps to every CPU and all the memory a
# container can see (8 vCPU and 8 GB on Railway); workstation GC keeps a small
# single instance near its working set.
EXPOSE 8096 5001
ENTRYPOINT ["/usr/local/bin/railway-entrypoint"]
