FROM golang:1.26.2-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /go_web .
# Present only when the build agent has them; GEOIP_DATABASE_PATH and RAILS_CREDENTIALS_PATH
# must stay unset otherwise.
RUN mkdir -p /geoip /credentials \
  && if [ -s GeoIP2-City.mmdb ]; then cp GeoIP2-City.mmdb /geoip/; fi \
  && if [ -s credentials/production.yml.enc ]; then cp credentials/production.yml.enc /credentials/; fi

FROM scratch

# The S3 client reaches AWS over TLS.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /geoip/ /geoip/
COPY --from=build /credentials/ /credentials/
COPY --from=build /go_web /go_web
USER 65534:65534
EXPOSE 3000
ENTRYPOINT ["/go_web"]
