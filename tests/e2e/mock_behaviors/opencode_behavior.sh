#!/usr/bin/env bash
# opencode_behavior.sh — OpenCode CLI specific mock behaviors
# Handles startup banner and OpenCode-specific mock prompts.

# OpenCode CLI startup banner
opencode_startup_banner() {
    echo "                                                      ▄"
    echo "                     █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█"
    echo "                     █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀"
    echo "                     ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀"
    echo ""
    echo "   ┃"
    echo "   ┃  Ask anything..."
    echo "   ┃"
    echo ""
    echo "                                                   ctrl+p commands"
}
