# Upstream -> Chainguard base image map (public, free tier: `latest` / `latest-dev` only)

| Upstream                     | Chainguard runtime                    | Build stage                              |
|------------------------------|---------------------------------------|------------------------------------------|
| python:*, python:*-slim      | cgr.dev/chainguard/python:latest      | cgr.dev/chainguard/python:latest-dev     |
| node:*, node:*-alpine        | cgr.dev/chainguard/node:latest        | cgr.dev/chainguard/node:latest-dev       |
| golang:* (runtime scratch)   | cgr.dev/chainguard/static:latest      | cgr.dev/chainguard/go:latest             |
| eclipse-temurin, openjdk     | cgr.dev/chainguard/jre:latest         | cgr.dev/chainguard/jdk:latest            |
| mcr.microsoft.com/dotnet/aspnet | cgr.dev/chainguard/aspnet-runtime:latest | cgr.dev/chainguard/dotnet-sdk:latest |
| nginx:*                      | cgr.dev/chainguard/nginx:latest (port 8080, nonroot) | n/a                       |
| alpine, debian, ubuntu       | cgr.dev/chainguard/wolfi-base:latest  | same (has apk)                           |
| scratch                      | cgr.dev/chainguard/static:latest      | n/a                                      |
| ruby, php, rust, busybox ... | see https://images.chainguard.dev     |                                          |

Notes
- Pinned version tags (e.g. `python:3.12`) require a Chainguard account / paid catalog; `latest` tracks the current stable.
- Chainguard images are Wolfi-based (glibc), so most Debian-built wheels work; Alpine (musl) assumptions do not apply.
- Default user `nonroot` (65532). `/home/nonroot` is writable; treat everything else as read-only.
