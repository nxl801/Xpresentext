# FineCat English point coverage

Xpresentext 0.6.1 integrates the pretrained FineCat-NLI Ultra L classifier published by dleemiller. The optional checkpoint and tokenizer are obtained separately, on the first explicit download. Speech and slide text are scored on the Mac. The reference model uses the UltraBERT sequence classifier. The bundled NumPy inference implementation, coverage decisions and presenter integration were written for Xpresentext.

- Model and tokenizer [dleemiller/finecat-nli-ultra-l](https://huggingface.co/dleemiller/finecat-nli-ultra-l/tree/5fe8dd8e605643793a091de2da0057697a558c9a)
- Model license [Apache License 2.0](LICENSE-Apache-2.0.txt)
- Pair encoding [Hugging Face Tokenizers](https://github.com/huggingface/tokenizers)
- Model files are pinned to revision `5fe8dd8e605643793a091de2da0057697a558c9a`. The helper verifies SHA-256 for each file before loading it.
