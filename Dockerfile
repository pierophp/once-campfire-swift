FROM swift:6.4-noble AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY Vendor ./Vendor
COPY Scripts ./Scripts
COPY reference ./reference
RUN python3 Scripts/generate-asset-manifest.py
RUN SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=2 swift build -j 2 -c release

FROM ubuntu:noble AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libatomic1 libicu74 libstdc++6 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/swift /usr/lib/swift
COPY --from=build /src/.build/release/campfire-swift /usr/local/bin/campfire-swift
ENV LD_LIBRARY_PATH=/usr/lib/swift/linux:/usr/lib/swift
ENV HTTP_PORT=80
EXPOSE 80
ENTRYPOINT ["/usr/local/bin/campfire-swift"]
