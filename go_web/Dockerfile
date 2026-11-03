FROM golang:1.26.2-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /go_web .
# Present only when the build agent has it; GEOIP_DATABASE_PATH must stay unset otherwise.
RUN mkdir -p /geoip && if [ -s GeoIP2-City.mmdb ]; then cp GeoIP2-City.mmdb /geoip/; fi

FROM scratch

# The S3 client reaches AWS over TLS.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /geoip/ /geoip/
COPY --from=build /go_web /go_web
USER 65534:65534
EXPOSE 3000
ENTRYPOINT ["/go_web"]
