FROM golang:1.26.2-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /resend_callbacks .

FROM scratch

COPY --from=build /resend_callbacks /resend_callbacks
USER 65534:65534
EXPOSE 3000
ENTRYPOINT ["/resend_callbacks"]
