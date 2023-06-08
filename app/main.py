from fastapi import FastAPI
from pydantic import BaseModel
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
from typing import List
import torch

tokenizer = AutoTokenizer.from_pretrained("tscholak/cxmefzzi")
model = AutoModelForSeq2SeqLM.from_pretrained("tscholak/cxmefzzi", device_map="auto", load_in_8bit=True, trust_remote_code=True)

class InferenceInput(BaseModel):
    question: str
    db_id: str
    table_names: List[str]
    columns: List[List[str]]

app = FastAPI()

def prepare_input_graphix_t5(question: str, db_id: str, table_names: List[str], columns: List[List[str]]):
    input = question + " | " + db_id

    for i in range(len(table_names)):
        input = input + " | " + table_names[i] + ": " + ", ".join(columns[i])

    input_ids = tokenizer(input, max_length=512, return_tensors="pt").input_ids
    return input_ids

@app.post("/inference")
def inference_graphix_t5(inference_input: InferenceInput) -> str:
    input_data = prepare_input_graphix_t5(inference_input.question, inference_input.db_id, inference_input.table_names, inference_input.columns)
    input_data = input_data.to(model.device)
    outputs = model.generate(inputs=input_data, max_length=512)
    result = tokenizer.decode(token_ids=outputs[0], skip_special_tokens=True)
    return {"result": result}
