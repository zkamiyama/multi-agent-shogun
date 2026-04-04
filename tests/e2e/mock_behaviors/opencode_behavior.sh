#!/usr/bin/env bash
# opencode_behavior.sh — OpenCode CLI specific mock behaviors
# Handles startup banner and OpenCode-specific mock prompts.

# OpenCode CLI startup banner
opencode_startup_banner() {
    echo "╭────────────────────────────────────────╮"
    echo "│      OpenCode CLI (mock)               │"
    echo "│        ? for shortcuts                 │"
    echo "╰────────────────────────────────────────╯"
    echo "                                    100% context left"
}
