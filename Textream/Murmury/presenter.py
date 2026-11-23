import sys

if __name__ == "__main__":
    from multiprocessing import freeze_support
    freeze_support()
    mode = sys.argv.pop(1)
    if mode == "panel":
        from panel import main
    elif mode == "coverage":
        from english_coverage.worker import main
    elif mode == "speech":
        from speech import main
    else:
        raise SystemExit("Expected panel, speech or coverage")
    raise SystemExit(main())
