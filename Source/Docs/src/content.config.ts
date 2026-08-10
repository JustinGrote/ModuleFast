import { defineCollection } from 'astro:content';
import { docsSchema } from '@astrojs/starlight/schema';
import moduleFastReferenceLoader from './plugins/module-fast-reference.js';
import readmeGuidesLoader from './plugins/readme-guides.js';

const docsLoader = moduleFastReferenceLoader();
const guidesLoader = readmeGuidesLoader();

export const collections = {
	docs: defineCollection({
		loader: {
			name: 'modulefast-content-loader',
			async load(context) {
				await docsLoader.load(context);
				await guidesLoader.load(context);
			},
		},
		schema: docsSchema(),
	}),
};
