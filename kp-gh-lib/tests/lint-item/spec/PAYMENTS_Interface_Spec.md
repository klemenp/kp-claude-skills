# Payments provider interface

Fixture spec for the lint-item suite. The provider is invented.

## 1. Overview

The shop talks to one payments provider over HTTPS with signed requests.

## 8. Capture and refunds

A payment is captured only after the provider confirms the authorisation. A refund names
the capture it reverses and is sent at most once.
