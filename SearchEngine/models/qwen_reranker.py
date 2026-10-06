"""
Qwen3-Reranker wrapper with the CrossEncoder.predict() interface used by search/reranker.py.

Qwen3-Reranker is a causal LM that answers "yes"/"no" to "does this document meet the query";
the score is P(yes) from the last-token logits (the model card's reference implementation).
On the gold eval pairs it separated relevant from irrelevant ayahs/hadiths far better than
bge-reranker-v2-m3 (e.g. Q 2:183 for "تعريف الصيام وأركانه": 0.81 vs 0.04).
"""
import logging
from pathlib import Path

import numpy as np
import torch

logger= logging.getLogger(__name__)

SYSTEM_PREFIX= ("<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and "
                "the Instruct provided. Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n<|im_start|>user\n")
# ~1.3 GB of fp32 logits per OpenVINO batch (Intel iGPU max single allocation is 4 GB)
OPENVINO_TOKENS_PER_BATCH= 2048
ASSISTANT_SUFFIX= "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"


class Qwen3Reranker:
    def __init__(self, model_name: str, instruction: str, max_length: int= 1024, device: str= "cpu",
                 openvino_dir: Path | None= None, openvino_device: str | None= None, openvino_int8: bool= False):
        from transformers import AutoTokenizer
        self.instruction= instruction
        self.max_length= max_length
        self.device= device
        self.backend= "torch"

        if openvino_dir is not None:
            from optimum.intel import OVModelForCausalLM
            local_dir= Path(openvino_dir) / (model_name.replace("/", "__") + ("-int8" if openvino_int8 else ""))
            ov_config= {"INFERENCE_PRECISION_HINT": "f32"} if openvino_device == "CPU" else {}
            if local_dir.exists():
                self.model= OVModelForCausalLM.from_pretrained(str(local_dir), device=openvino_device, use_cache=False,
                                                               ov_config=ov_config)
                self.tokenizer= AutoTokenizer.from_pretrained(str(local_dir), padding_side="left")
            else:
                logger.info(f"  Exporting {model_name} to OpenVINO (one-time) ...")
                self.model= OVModelForCausalLM.from_pretrained(model_name, export=True, device=openvino_device,
                                                               use_cache=False, stateful=False, ov_config=ov_config,
                                                               load_in_8bit=openvino_int8)
                self.tokenizer= AutoTokenizer.from_pretrained(model_name, padding_side="left")
                self.model.save_pretrained(str(local_dir))
                self.tokenizer.save_pretrained(str(local_dir))
            self.backend= f"openvino:{openvino_device}{':int8' if openvino_int8 else ''}"
        else:
            from transformers import AutoModelForCausalLM
            self.tokenizer= AutoTokenizer.from_pretrained(model_name, padding_side="left")
            dtype= torch.float16 if device == "cuda" else torch.float32
            self.model= AutoModelForCausalLM.from_pretrained(model_name, dtype=dtype).to(device).eval()

        self.yes_id= self.tokenizer.convert_tokens_to_ids("yes")
        self.no_id= self.tokenizer.convert_tokens_to_ids("no")
        self.prefix_ids= self.tokenizer.encode(SYSTEM_PREFIX, add_special_tokens=False)
        self.suffix_ids= self.tokenizer.encode(ASSISTANT_SUFFIX, add_special_tokens=False)

    def _encode(self, query: str, document: str) -> list[int]:
        body= self.tokenizer.encode(f"<Instruct>: {self.instruction}\n<Query>: {query}\n<Document>: {document}",
                                    add_special_tokens=False)
        budget= self.max_length - len(self.prefix_ids) - len(self.suffix_ids)
        return self.prefix_ids + body[:budget] + self.suffix_ids

    def predict(self, pairs, batch_size: int= 8, show_progress_bar: bool= False, convert_to_numpy: bool= True, **_):
        encoded= [self._encode(q, d) for q, d in pairs]
        order= sorted(range(len(encoded)), key=lambda i: len(encoded[i]))   # similar lengths -> less padding
        scores= np.zeros(len(encoded), dtype="float32")
        # the exported OpenVINO graph returns logits for every position (batch x seq x 151k vocab),
        # so OpenVINO batches are capped by padded token count; torch asks for the last position only
        token_budget= OPENVINO_TOKENS_PER_BATCH if self.backend != "torch" else None
        batches, current= [], []
        for i in order:
            longest= max([len(encoded[j]) for j in current] + [len(encoded[i])])
            if current and (len(current) >= batch_size or (token_budget and longest * (len(current) + 1) > token_budget)):
                batches.append(current)
                current= []
            current.append(i)
        if current:
            batches.append(current)

        for idx in batches:
            batch= self.tokenizer.pad({"input_ids": [encoded[i] for i in idx]}, padding=True, return_tensors="pt")
            with torch.no_grad():
                if self.backend == "torch":
                    batch= {k: v.to(self.device) for k, v in batch.items()}
                    logits= self.model(**batch, logits_to_keep=1).logits[:, -1, :]
                else:
                    logits= self.model(**batch).logits[:, -1, :]
                logits= torch.as_tensor(logits).float()
                pair_logits= torch.stack([logits[:, self.no_id], logits[:, self.yes_id]], dim=1)
                probs= torch.softmax(pair_logits, dim=1)[:, 1].cpu().numpy()
            scores[idx]= probs
        return scores
