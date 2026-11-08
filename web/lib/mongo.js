// One MongoClient for the whole app (the database name comes from MONGO_URL).
import { MongoClient } from 'mongodb';

const state = (globalThis.__qbMongo ??= { client: null, ready: null });

export async function mongoDb() {
  if (!state.ready) {
    state.client = new MongoClient(process.env.MONGO_URL, { serverSelectionTimeoutMS: 5000 });
    state.ready = state.client.connect();
  }
  await state.ready;
  return state.client.db();
}

export async function closeMongo() {
  if (state.client) await state.client.close();
  state.client = null;
  state.ready = null;
}
