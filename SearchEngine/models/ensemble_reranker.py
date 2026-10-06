"""
Weighted score ensemble of two rerankers with the CrossEncoder.predict() interface.

bge-reranker-v2-m3 orders candidates well but under-rates relevant ayahs/hadiths whose wording
differs from the query; Qwen3-Reranker separates relevant from irrelevant well but saturates
(0.9+ for anything on-topic), so on its own it cannot order the top. Both output a probability
in [0, 1], so a weighted mean keeps bge's ordering and lets Qwen veto off-topic items.
"""
import numpy as np


class EnsembleReranker:
    def __init__(self, members: list[tuple[str, object, float]]):
        # (name, model, weight)
        self.members= members
        self.backend= "+".join(f"{name}:{weight:g}" for name, _, weight in members)

    def predict_members(self, pairs, **kwargs) -> list[np.ndarray]:
        return [np.asarray(model.predict(pairs, **kwargs), dtype="float32") for _, model, _ in self.members]

    def predict(self, pairs, second_weights=None, **kwargs):
        """second_weights: optional per-pair weight of the second member (the first gets 1 - w)."""
        member_scores= self.predict_members(pairs, **kwargs)
        if second_weights is None:
            total= sum(weight for _, _, weight in self.members)
            return sum((weight / total) * scores for (_, _, weight), scores in zip(self.members, member_scores))
        w= np.asarray(second_weights, dtype="float32")
        return (1 - w) * member_scores[0] + w * member_scores[1]
