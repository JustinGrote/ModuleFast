import { glob } from 'astro/loaders';

const repositoryRoot = new URL('../../../../', import.meta.url);

export default function moduleFastDocsLoader() {
	return glob({
		base: repositoryRoot,
		pattern: [
			'Source/Docs/src/content/docs/**/[^_]*.{md,mdx}',
			'Docs/ModuleFast/**/[^_]*.{md,mdx}',
		],
		generateId: ({ entry }) => {
			if (entry.startsWith('Docs/ModuleFast/')) {
				return `reference/${entry.slice('Docs/ModuleFast/'.length).replace(/\.(md|mdx)$/i, '').toLowerCase()}`;
			}
			return entry
				.slice('Source/Docs/src/content/docs/'.length)
				.replace(/\.(md|mdx)$/i, '')
				.toLowerCase();
		},
	});
}
